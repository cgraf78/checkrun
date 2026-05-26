#!/usr/bin/env bash
# autolint implementation — lint files by extension.
# Requires yq when at least one lint step is planned; jq additionally when
# --json is selected. The check is lazy (inside _lint_one, after planning)
# so ignored files skip cleanly on lean hosts.
# No-ops gracefully if a linter is not installed.
# Respects per-repo config files.
#
# Usage: autolint [--fix] [--json] <file> [file...]

set -u

CHECKRUN_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$CHECKRUN_LIB_DIR" == "${BASH_SOURCE[0]}" ]] && CHECKRUN_LIB_DIR=.

# shellcheck source=common.sh
. "$CHECKRUN_LIB_DIR/common.sh"

# Adapter contract:
# - missing tools are silent no-ops so hooks keep working across partial hosts
# - diagnostics go to stdout/stderr in the caller's selected format
# - non-zero returns mean findings or tool errors, not "tool unavailable"
# - adapters read `fix` and `json` from `_autolint_main` via Bash dynamic scope
# Keep backend adapters grouped by domain. `core.sh` must load first because the
# other adapters share its diagnostic helpers and severity normalizer.
# shellcheck source=linters/core.sh
. "$CHECKRUN_LIB_DIR/linters/core.sh"
# shellcheck source=linters/shell.sh
. "$CHECKRUN_LIB_DIR/linters/shell.sh"
# shellcheck source=linters/web.sh
. "$CHECKRUN_LIB_DIR/linters/web.sh"
# shellcheck source=linters/build.sh
. "$CHECKRUN_LIB_DIR/linters/build.sh"
# shellcheck source=linters/config.sh
. "$CHECKRUN_LIB_DIR/linters/config.sh"
# shellcheck source=linters/languages.sh
. "$CHECKRUN_LIB_DIR/linters/languages.sh"
# shellcheck source=linters/docs.sh
. "$CHECKRUN_LIB_DIR/linters/docs.sh"
# shellcheck source=linters/github-actions.sh
. "$CHECKRUN_LIB_DIR/linters/github-actions.sh"

# `--fix` is opt-in. Unlike autoformat (which always mutates), autolint
# defaults to read-only: edit-hook callers want diagnostics without
# surprise fixes. Pass `--fix` explicitly — e.g. from the CLI — when
# the caller wants ruff/biome/rumdl to also apply fixes.
#
# `--json` emits one JSON object per diagnostic on stdout, in a unified
# schema: {path,line,col,end_line?,end_col?,severity,code?,message,source}.
# Line/col are 1-based. Designed for nvim-lint so the editor's
# diagnostics are produced by exactly the same dispatch path as the
# post-edit and pre-commit hooks. Tool stderr is suppressed in json
# mode so the output stream stays parseable.
#
# Every file arg is linted independently. The final exit code is
# non-zero if any file reports diagnostics or tool errors.
_autolint_usage() {
  printf '%s\n' \
    "Usage: autolint [--fix] [--json] [-h|--help] <file> [file...]" \
    "" \
    "Lint files by extension. Unsupported files, missing files, ignored files," \
    "and files whose linter is not installed are skipped." \
    "" \
    "Supported file types:" \
    "  Build:     .bzl, BUCK, BUILD, CMakeLists.txt, .cmake, Makefile, GNUmakefile, .mk" \
    "  CI:        .github/workflows/*.yml, .github/workflows/*.yaml" \
    "  Config:    .editorconfig, .toml, git config, tmux.conf, crontab" \
    "  Container: Dockerfile, Containerfile" \
    "  Docs/text: .md and plain text via typos when available" \
    "  Go:        .go" \
    "  Java:      .java" \
    "  Lua:       .lua" \
    "  PHP:       .php" \
    "  Python:    .py" \
    "  Ruby:      .rb" \
    "  Rust:      .rs" \
    "  Shell:     .sh, .bash, .zsh, extensionless files with a shell shebang, .bashrc, .zshrc, .envrc" \
    "  Systemd:   .automount, .device, .mount, .path, .scope, .service, .slice, .socket, .swap, .target, .timer" \
    "  Web/data:  .css, .js, .jsx, .ts, .tsx, .json, .jsonc, .html, .htm" \
    "" \
    "Options:" \
    "  --fix       Apply safe linter fixes where supported." \
    "  --json      Emit one unified JSON diagnostic per output line." \
    "  -h, --help  Show this help and exit." \
    "" \
    "Environment:" \
    "  CHECKRUN_AUTOLINT_JOBS  Override parallel worker count (default: min(cores, 8))." \
    "  CHECKRUN_AUTOLINT_DIR   Fallback config directory (defaults to CHECKRUN_AUTOFORMAT_DIR)."
}

_lint_one_with_plan() {
  # Dispatch a pre-built plan file. Split out of _lint_one so the parallel
  # parent process can plan many files in a single Python call (see
  # _autolint_pre_plan), then hand each worker its own pre-built plan without
  # paying for a per-file `python3 registry.py` startup. The file path itself
  # is carried inside each plan record, so this helper only needs the plan
  # file location.
  #
  # An empty plan file means "no lint steps" (unsupported / ignored): return
  # cleanly without checking yq/jq, so missing-tool hosts can still
  # save-on-edit unsupported file types.
  local plan_file="$1"
  local path filetype step_phase adapter config_source config_path
  local rc=0 tool_rc dir

  [ -s "$plan_file" ] || return 0

  if ! command -v yq >/dev/null 2>&1; then
    echo "autolint: yq is required" >&2
    return 1
  fi
  if [ "$json" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
    echo "autolint: jq is required for --json" >&2
    return 1
  fi

  while IFS= read -r -d '' path &&
    IFS= read -r -d '' filetype &&
    IFS= read -r -d '' step_phase &&
    IFS= read -r -d '' adapter &&
    IFS= read -r -d '' config_source &&
    IFS= read -r -d '' config_path; do
    dir=$(dirname "$path")
    _lint_dispatch "$adapter" "$path" "$filetype" "$step_phase" "$config_source" "$config_path" "$dir"
    tool_rc=$?
    # A missing adapter is a Checkrun integrity failure, not a lint diagnostic.
    # Preserve that private sentinel instead of allowing a later ordinary lint
    # finding to overwrite it with exit 1.
    if [ "$tool_rc" -eq 125 ]; then
      rc=$tool_rc
      break
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  done <"$plan_file"

  return "$rc"
}

_lint_one() {
  # Plan one file inline (one Python invocation per call) and dispatch. Used by
  # the sequential paths (--fix mode and --jobs=1 fallback). The parallel paths
  # use the batched _autolint_pre_plan helper plus _lint_one_with_plan so the
  # Python planner runs once total, not once per file.
  local file="$1"
  local rc tool_rc plan_file

  plan_file=$(_checkrun_tempfile) || {
    echo "autolint: could not create registry plan temp file" >&2
    return 1
  }
  _checkrun_registry shell-plan --phase lint -- "$file" >"$plan_file"
  tool_rc=$?
  if [ "$tool_rc" -ne 0 ]; then
    _checkrun_remove "$plan_file"
    return "$tool_rc"
  fi

  _lint_one_with_plan "$plan_file"
  rc=$?
  _checkrun_remove "$plan_file"
  return "$rc"
}

_autolint_pre_plan() {
  # Plan many files in a single Python invocation. Writes `<index>.plan` per
  # input file into a fresh dir whose path is echoed on stdout for the caller
  # to capture. Returns non-zero (and removes the dir) if the planner itself
  # fails — empty per-file plans are legitimate skips, not failures.
  local out_dir
  out_dir=$(mktemp -d "${TMPDIR:-/tmp}/autolint-plans.XXXXXX") || return 1
  if ! _checkrun_registry shell-plan --output-dir "$out_dir" --phase lint -- "$@"; then
    rm -rf "$out_dir"
    return 1
  fi
  printf '%s\n' "$out_dir"
}

_lint_dispatch() {
  local adapter="$1" file="$2" filetype="$3" step_phase="$4" config_source="$5" config_path="$6" dir="$7"

  # Dispatch only by registry adapter id. Filetype remains available for small
  # adapter details, such as shellcheck language hints, but it no longer decides
  # whether a linter runs.
  case "$adapter" in
    actionlint) _lint_actionlint "$file" ;;
    biome-lint) _lint_biome "$file" "$dir" "$config_source" "$config_path" ;;
    buildifier-lint) _lint_buildifier "$file" ;;
    checkmake) _lint_checkmake "$file" "$dir" "$config_source" "$config_path" ;;
    cmake-lint) _lint_cmake "$file" "$dir" "$config_source" "$config_path" ;;
    crontab) _lint_crontab "$file" ;;
    editorconfig-checker) _lint_editorconfig "$file" ;;
    git-config) _lint_git_config "$file" ;;
    golangci-lint) _lint_go "$file" "$dir" "$config_source" "$config_path" ;;
    google-java-format-lint) _lint_java "$file" ;;
    hadolint) _lint_dockerfile "$file" "$dir" "$config_source" "$config_path" ;;
    php) _lint_php "$file" ;;
    rubocop-lint) _lint_ruby "$file" "$dir" "$config_source" "$config_path" ;;
    ruff-lint) _lint_ruff "$file" "$dir" "$config_source" "$config_path" ;;
    rumdl-lint) _lint_rumdl "$file" "$dir" "$config_source" "$config_path" ;;
    rust-clippy) _lint_rust "$file" "$dir" ;;
    schema-lint) _lint_schema "$file" ;;
    selene) _lint_selene "$file" "$dir" "$config_source" "$config_path" ;;
    shellcheck) _lint_sh "$file" "$dir" "$(_shellcheck_lang_hint "$file")" "$config_source" "$config_path" ;;
    superhtml-lint) _lint_superhtml "$file" ;;
    systemd-analyze) _lint_systemd_unit "$file" ;;
    taplo-lint) _lint_taplo "$file" "$dir" "$config_source" "$config_path" ;;
    tmux) _lint_tmux_config "$file" ;;
    typos) _lint_typos "$file" "$dir" "$config_source" "$config_path" ;;
    zizmor) _lint_zizmor "$file" ;;
    zsh-lint) _lint_zsh "$file" ;;
    *)
      echo "autolint: unknown linter adapter: $adapter" >&2
      return 125
      ;;
  esac
}

_autolint_default_jobs() {
  local cores
  if command -v getconf >/dev/null 2>&1; then
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4\n')
  elif command -v sysctl >/dev/null 2>&1; then
    cores=$(sysctl -n hw.ncpu 2>/dev/null || printf '4\n')
  else
    cores=4
  fi
  case "$cores" in
    '' | *[!0-9]*) cores=4 ;;
  esac

  # Keep the default bounded. Hook latency improves once independent linters
  # overlap, but unbounded fan-out is hostile to laptops and large commits.
  if [ "$cores" -gt 8 ]; then
    printf '8\n'
  elif [ "$cores" -lt 1 ]; then
    printf '1\n'
  else
    printf '%s\n' "$cores"
  fi
}

_autolint_merge_rc() {
  local current="$1" incoming="$2"

  # Ordinary lint findings use exit 1, while registry/plumbing failures use
  # stronger codes such as 2 or the private unknown-adapter sentinel 125. In a
  # multi-file run those structural failures must survive later lint findings so
  # CI points at the broken Checkrun contract instead of looking like normal
  # source diagnostics.
  if [ "$incoming" -eq 0 ]; then
    printf '%s\n' "$current"
  elif [ "$current" -eq 125 ] || [ "$incoming" -eq 125 ]; then
    printf '125\n'
  elif [ "$current" -eq 2 ] || [ "$incoming" -eq 2 ]; then
    printf '2\n'
  elif [ "$current" -ne 0 ]; then
    printf '%s\n' "$current"
  else
    printf '%s\n' "$incoming"
  fi
}

_autolint_run_file_batch() {
  # Barrier-style: spawn every file in the wave concurrently, then wait for
  # them all before returning. Output is preserved in file_args order via the
  # parallel arrays of per-file temp files. Used as a fallback on bash <4.3
  # where `wait -n` is unavailable; on bash 4.3+ the pool path below keeps
  # ${jobs} workers in flight at all times instead of waiting at wave
  # boundaries.
  #
  # Arg layout: <plan_dir> <base_index> <file...>. plan_dir holds per-file
  # plans named `<global_index>.plan` produced by _autolint_pre_plan. The
  # base_index lets each wave find its slice of the global plan dir, so the
  # same pre-built dir serves every wave without renumbering.
  local plan_dir="$1" base_index="$2"
  shift 2
  local rc=0 file_rc stdout_file stderr_file pid index global_index
  local -a batch_files=("$@")
  local -a batch_pids=() batch_stdout_files=() batch_stderr_files=()

  for index in "${!batch_files[@]}"; do
    global_index=$((base_index + index))
    stdout_file=$(mktemp "${TMPDIR:-/tmp}/autolint-stdout.XXXXXX")
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/autolint-stderr.XXXXXX")
    (
      _lint_one_with_plan "$plan_dir/$global_index.plan"
    ) >"$stdout_file" 2>"$stderr_file" &
    pid=$!
    batch_pids+=("$pid")
    batch_stdout_files+=("$stdout_file")
    batch_stderr_files+=("$stderr_file")
  done

  for index in "${!batch_files[@]}"; do
    pid=${batch_pids[$index]}
    stdout_file=${batch_stdout_files[$index]}
    stderr_file=${batch_stderr_files[$index]}
    if wait "$pid"; then
      file_rc=0
    else
      file_rc=$?
    fi
    [ -s "$stdout_file" ] && cat "$stdout_file"
    [ -s "$stderr_file" ] && cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    rc=$(_autolint_merge_rc "$rc" "$file_rc")
  done

  return "$rc"
}

# Bash 4.3 introduced `wait -n` (wait for any one child). Older shells —
# including macOS's system bash 3.2 — must use the barrier path above.
_autolint_supports_pool() {
  if [ "${BASH_VERSINFO[0]}" -gt 4 ]; then
    return 0
  fi
  if [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; then
    return 0
  fi
  return 1
}

_autolint_run_files_pool() {
  # Pool-style: maintain up to ${jobs} workers in flight. When any worker
  # finishes (via `wait -n`), spawn the next file immediately rather than
  # waiting for the whole wave. One slow file (e.g. a Rust file that triggers
  # clippy) no longer idles the other ${jobs-1} workers for the rest of the
  # wave. Output is still emitted in file_args order at the end to keep
  # diagnostics deterministic for users and editor consumers — buffering is
  # already required by the per-file temp file scheme.
  #
  # Each worker reads a pre-built plan file from `plan_dir/<index>.plan`,
  # which _autolint_main built in one Python call before invoking us. That
  # avoids paying one `python3 registry.py` startup per file.
  local jobs="$1" plan_dir="$2"
  shift 2
  local -a files=("$@")
  local n=${#files[@]}
  local -a pids=() stdouts=() stderrs=()
  local rc=0 file_rc i next=0 in_flight=0 stdout_file stderr_file

  # Spawn-and-reap loop. `wait -n` blocks until any one child finishes; its
  # exit status reflects that child but we don't need to map it back to a pid
  # here — we'll wait on each specific pid in the in-order pass below to pick
  # up the correct per-file rc. A wait on an already-finished child returns
  # immediately with its stored exit status, so this is cheap.
  while [ "$next" -lt "$n" ] || [ "$in_flight" -gt 0 ]; do
    while [ "$next" -lt "$n" ] && [ "$in_flight" -lt "$jobs" ]; do
      stdout_file=$(mktemp "${TMPDIR:-/tmp}/autolint-stdout.XXXXXX")
      stderr_file=$(mktemp "${TMPDIR:-/tmp}/autolint-stderr.XXXXXX")
      (
        _lint_one_with_plan "$plan_dir/$next.plan"
      ) >"$stdout_file" 2>"$stderr_file" &
      pids[next]=$!
      stdouts[next]=$stdout_file
      stderrs[next]=$stderr_file
      next=$((next + 1))
      in_flight=$((in_flight + 1))
    done

    if [ "$in_flight" -gt 0 ]; then
      # `wait -n` returns 127 only when there are no children to wait for.
      # Our in_flight counter guards against that case, so any exit status
      # here belongs to a real worker.
      wait -n 2>/dev/null || true
      in_flight=$((in_flight - 1))
    fi
  done

  for i in "${!files[@]}"; do
    if wait "${pids[$i]}"; then
      file_rc=0
    else
      file_rc=$?
    fi
    [ -s "${stdouts[$i]}" ] && cat "${stdouts[$i]}"
    [ -s "${stderrs[$i]}" ] && cat "${stderrs[$i]}" >&2
    rm -f "${stdouts[$i]}" "${stderrs[$i]}"
    rc=$(_autolint_merge_rc "$rc" "$file_rc")
  done

  return "$rc"
}

_autolint_main() {
  local fix=0 json=0 rc=0 jobs start file lint_file arg
  local -a file_args=() lint_files=()

  for arg in "$@"; do
    case "$arg" in
      --fix) fix=1 ;;
      --json) json=1 ;;
      -h | --help)
        _autolint_usage
        return 0
        ;;
      *) file_args+=("$arg") ;;
    esac
  done

  [ "${#file_args[@]}" -eq 0 ] && return 0

  # Fallback-config dir. Mirrors the resolution logic in registry.py's
  # `_config_root`: prefer CHECKRUN_AUTOLINT_DIR, then CHECKRUN_AUTOFORMAT_DIR
  # (because several backends share one policy file for formatting and
  # linting), then the personal-config default. The bash side needs the
  # fallback explicitly because we EXPORT the result below so Python sees the
  # bash-resolved absolute path — without the mirror, exporting a defaulted
  # AUTOLINT_DIR would shadow Python's AUTOFORMAT_DIR fallback.
  CHECKRUN_AUTOLINT_DIR="${CHECKRUN_AUTOLINT_DIR:-${CHECKRUN_AUTOFORMAT_DIR:-$HOME/.config/autoformat}}"

  # Resolve relative CHECKRUN_AUTOLINT_DIR values before any linter-specific cwd
  # changes. Config paths passed on the CLI should name the same file
  # regardless of where the backend command eventually runs.
  if [ -d "$CHECKRUN_AUTOLINT_DIR" ]; then
    CHECKRUN_AUTOLINT_DIR=$(_abs_dir "$CHECKRUN_AUTOLINT_DIR")
  fi

  # Export so the Python planner subprocess sees the bash-resolved absolute
  # path. Without `export`, the variable is shell-local and Python's
  # os.environ.get() returns None, falling back to its own default — which
  # works by coincidence but means the bash resolution above is effectively
  # dead code in that case.
  export CHECKRUN_AUTOLINT_DIR

  for file in "${file_args[@]}"; do
    if lint_file=$(_lintable_path "$file"); then
      lint_files+=("$lint_file")
    fi
  done

  [ "${#lint_files[@]}" -eq 0 ] && return 0

  if [ "$fix" -eq 1 ]; then
    # Keep mutation mode sequential. Several backends operate at package/project
    # scope even when they receive one file, so parallel fixes can race on shared
    # source files or tool caches. Read-only linting below is safe to overlap.
    for file in "${lint_files[@]}"; do
      _lint_one "$file"
      rc=$(_autolint_merge_rc "$rc" "$?")
    done
  else
    jobs=${CHECKRUN_AUTOLINT_JOBS:-$(_autolint_default_jobs)}
    case "$jobs" in
      '' | *[!0-9]*) jobs=1 ;;
    esac
    [ "$jobs" -lt 1 ] && jobs=1
    if [ "$jobs" -eq 1 ] ||
      ! command -v mktemp >/dev/null 2>&1 ||
      ! command -v cat >/dev/null 2>&1 ||
      ! command -v rm >/dev/null 2>&1; then
      # Tests and minimal hook environments sometimes constrain PATH to only the
      # backend being exercised. In that mode correctness is more important than
      # concurrency, so fall back to the historical no-temp-file execution path.
      for file in "${lint_files[@]}"; do
        _lint_one "$file"
        rc=$(_autolint_merge_rc "$rc" "$?")
      done
    else
      # Plan every file in a single Python invocation. The pre-built plan
      # directory survives the spawn/wait below and is cleaned up after the
      # runner returns. If pre-planning itself fails (registry corruption,
      # tmpdir unavailable), fall back to per-file planning inside _lint_one
      # so a broken host gets the same diagnostic flow it used to.
      local plan_dir=""
      plan_dir=$(_autolint_pre_plan "${lint_files[@]}") || plan_dir=""
      if [ -n "$plan_dir" ] && _autolint_supports_pool; then
        # Modern bash: keep ${jobs} workers in flight at all times.
        _autolint_run_files_pool "$jobs" "$plan_dir" "${lint_files[@]}"
        rc=$(_autolint_merge_rc "$rc" "$?")
      elif [ -n "$plan_dir" ]; then
        # Legacy bash (e.g. macOS system bash 3.2): wave-style barrier
        # batching. Pass the plan_dir + the global base index of each wave so
        # workers find their pre-built plan via plan_dir/<global_index>.plan.
        for ((start = 0; start < ${#lint_files[@]}; start += jobs)); do
          _autolint_run_file_batch "$plan_dir" "$start" \
            "${lint_files[@]:start:jobs}"
          rc=$(_autolint_merge_rc "$rc" "$?")
        done
      else
        # Pre-planning failed — fall through to per-file planning. Each
        # _lint_one call runs its own python3 invocation, matching legacy
        # behavior, so the user still gets diagnostics instead of a silent
        # skip.
        for file in "${lint_files[@]}"; do
          _lint_one "$file"
          rc=$(_autolint_merge_rc "$rc" "$?")
        done
      fi
      [ -n "$plan_dir" ] && rm -rf "$plan_dir"
    fi
  fi

  return "$rc"
}
