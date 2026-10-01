#!/usr/bin/env bash
# autolint implementation — lint files by extension.
# Requires yq when at least one lint step is planned; jq additionally when
# --json is selected. The check is lazy (inside _lint_one, after planning)
# so ignored files skip cleanly on lean hosts.
# No-ops gracefully if a linter is not installed.
# Respects per-repo config files.
#
# Usage: autolint [--fix] [--json] <file> [file...]
#        autolint [--fix] [--json] --files0-from FILE|-

set -u

CHECKRUN_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$CHECKRUN_LIB_DIR" == "${BASH_SOURCE[0]}" ]] && CHECKRUN_LIB_DIR=.

# shellcheck source=common.sh
. "$CHECKRUN_LIB_DIR/common.sh"

# Adapter contract:
# - missing tools are silent no-ops so hooks keep working across partial hosts
# - diagnostics go to stdout/stderr in the caller's selected format
# - non-zero returns mean findings or tool errors, not "tool unavailable"
# - adapters read `fix` and `json` from `_autolint_run` via Bash dynamic scope
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
# `--json` emits one JSON object per diagnostic on stdout. The durable contract
# lives in share/checkrun/schemas/diagnostics.schema.json so editor adapters and
# shell producers can validate the same 1-based diagnostic shape instead of
# retyping it from this comment. Tool stderr is suppressed in json mode so the
# output stream stays parseable.
#
# Every file arg is linted independently. The final exit code is
# non-zero if any file reports diagnostics or tool errors.
_autolint_usage() {
  printf '%s\n' \
    "Usage: autolint [--fix] [--json] [-h|--help] <file> [file...]" \
    "       autolint [--fix] [--json] --files0-from FILE|-" \
    "" \
    "Lint files by extension. Missing files, ignored files, and files whose" \
    "linter is not installed are skipped. Files without a backend linter below" \
    "still get typos spelling checks and any configured schema validation." \
    "" \
    "Supported file types:" \
    "  Build:     .bzl, BUCK, BUILD, CMakeLists.txt, .cmake, Makefile, GNUmakefile, .mk, .mak" \
    "  C/C++:     .c, .cc, .cpp, .cxx, .h, .hpp, .hxx (with compile_commands.json or compile_flags.txt in the file's directory or an ancestor)" \
    "  CI:        .github/workflows/*.yml, .github/workflows/*.yaml" \
    "  Config:    .editorconfig, .toml, git config, tmux.conf, crontab" \
    "  Container: Dockerfile, Containerfile" \
    "  Docs/text: .md" \
    "  Java:      .java" \
    "  Lua:       .lua" \
    "  Nix:       .nix" \
    "  PHP:       .php" \
    "  Protobuf:  .proto" \
    "  Python:    .py" \
    "  Ruby:      .rb" \
    "  Shell:     .sh, .bash, .zsh, extensionless files with a shell shebang, .bashrc, .zshrc, .envrc" \
    "  Spelling:  all files via typos when available" \
    "  Systemd:   .automount, .device, .mount, .path, .scope, .service, .slice, .socket, .swap, .target, .timer" \
    "  Web/data:  .css, .scss, .less, .js, .jsx, .ts, .tsx, .json, .jsonc, .html, .htm" \
    "" \
    "Options:" \
    "  --fix       Apply safe linter fixes where supported." \
    "  --files0-from FILE|-" \
    "              Read NUL-delimited paths from FILE or stdin instead of argv." \
    "  --json      Emit one unified JSON diagnostic per output line." \
    "  --          End option parsing; treat later arguments as paths." \
    "  -h, --help  Show this help and exit." \
    "" \
    "Environment:" \
    "  CHECKRUN_AUTOLINT_JOBS  Override parallel worker count (default: min(cores, 8))." \
    "  CHECKRUN_CONFIG_DIR       Fallback config directory (default: XDG config root)."
}

_autolint_read_files0() {
  local display="$1" file
  # `_autolint_run` owns this dynamically scoped array. Keeping it local to
  # the complete invocation prevents repeated calls in one sourced shell from
  # sharing decoded paths while still supporting Bash 3.2 without namerefs.
  _autolint_files0_args=()
  if [ "$display" = "-" ]; then
    # EOF is a valid empty manifest, but Bash gives a failed read with an empty
    # field for both EOF and descriptor errors. Reject a closed descriptor and
    # directory source before reading so an invalid stream cannot become a
    # silent no-op. Pipes, regular files, sockets, and terminals remain valid.
    if { [ ! -r /dev/stdin ] && [ ! -r /dev/fd/0 ]; } ||
      [ -d /dev/stdin ] || [ -d /dev/fd/0 ]; then
      echo "autolint: --files0-from - requires a readable stream on standard input" >&2
      return 2
    fi
    display="standard input"
  fi

  # Bash's NUL-delimited read preserves the same raw path bytes as argv. Keep
  # decoding in this process so stdin can be consumed completely before any
  # backend starts; subsequent linters therefore inherit EOF rather than a
  # producer pipe that could block or steal tool input.
  while :; do
    file=""
    if IFS= read -r -d '' file; then
      if [ -z "$file" ]; then
        echo "autolint: --files0-from contains an empty path: $display" >&2
        return 2
      fi
      _autolint_files0_args+=("$file")
    else
      if [ -n "$file" ]; then
        echo "autolint: --files0-from must end with NUL: $display" >&2
        return 2
      fi
      break
    fi
  done
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
    _checkrun_path_dir dir "$path"
    _lint_dispatch "$adapter" "$path" "$filetype" "$step_phase" "$config_source" "$config_path" "$dir"
    tool_rc=$?
    # A missing adapter is a Checkrun integrity failure, not a lint diagnostic.
    # Preserve that private sentinel instead of allowing a later ordinary lint
    # finding to overwrite it with exit 1.
    if [ "$tool_rc" -eq 125 ]; then
      rc=$tool_rc
      break
    fi
    # Any status other than clean or tool failure may be a finding. Record it
    # before the sticky 2 below can hide it from CHECKRUN_AUTOLINT_REPORT. If
    # the record cannot be written, fail as an integrity error: a report that
    # silently misses a finding would let a caller tolerate this file's exit 2.
    if [ "$tool_rc" -ne 0 ] && [ "$tool_rc" -ne 2 ]; then
      _autolint_note_findings || {
        rc=125
        break
      }
    fi
    # A tool/config failure (2) is sticky across steps of one file, as it is
    # across files in _autolint_merge_rc, so a later step's ordinary finding
    # cannot report a broken spelling config as a normal lint failure. Other
    # statuses keep last-nonzero-wins. Inlined so the hot per-step loop does
    # not fork a command substitution.
    [ "$tool_rc" -ne 0 ] && [ "$rc" -ne 2 ] && rc=$tool_rc
  done <"$plan_file"

  return "$rc"
}

_lint_one() {
  # Plan one file inline (one Python invocation per call) and dispatch. Used
  # only when no planner scratch can be allocated at all. Every other path,
  # including --fix and the minimal-PATH fallback, uses _autolint_pre_plan
  # plus _lint_one_with_plan so the Python planner runs once total.
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
  # input file into the caller-owned directory. The caller allocates and
  # records that directory before this interruptible planner runs, so every
  # return path can remove the exact invocation scratch without a glob.
  # Empty per-file plans are legitimate skips, not failures.
  local out_dir="$1" manifest manifest_outside=0 plan_rc=0
  shift
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
  # Keep the common one-file edit hook direct. Every multi-file request uses a
  # manifest: relative paths can grow substantially when normalization makes
  # them absolute, so a fixed byte threshold cannot guarantee that the second
  # exec still fits alongside an arbitrarily large inherited environment.
  if [ "${_autolint_force_manifest:-0}" -eq 0 ] && [ "$#" -eq 1 ]; then
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
    _checkrun_registry shell-plan --output-dir "$out_dir" --phase lint -- "$@"
    return
  fi
  # Sley can hand autolint thousands of files through a manifest, but expanding
  # the normalized array into the Python planner's argv would merely move the
  # same ARG_MAX failure one process deeper. Stage a private manifest inside the
  # already-owned plan directory so the planner still runs exactly once with a
  # bounded argv. mktemp supplies mode 0600 independent of the caller's umask.
  # Without mktemp (minimal PATH), use the noclobber tempfile helper and
  # remove the manifest once the planner has consumed it, since it lives
  # outside the caller-owned directory on that path. A present-but-failing
  # mktemp keeps its historical 125 diagnostic.
  if command -v mktemp >/dev/null 2>&1; then
    manifest=$(mktemp "$out_dir/files0.XXXXXX") || {
      echo "autolint: could not create registry input manifest" >&2
      return 125
    }
  elif manifest=$(_checkrun_tempfile); then
    manifest_outside=1
  else
    echo "autolint: could not create registry input manifest" >&2
    return 125
  fi
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || {
    [ "$manifest_outside" -eq 1 ] && _checkrun_remove "$manifest"
    return "$_autolint_cancel_status"
  }
  if ! printf '%s\0' "$@" >"$manifest"; then
    echo "autolint: could not write registry input manifest" >&2
    [ "$manifest_outside" -eq 1 ] && _checkrun_remove "$manifest"
    return 125
  fi
  # A trap can latch while the shell builtin is writing a large manifest. Do
  # not start a new planner after that signal: it was not alive to receive the
  # already-delivered process-group cancellation and could otherwise hang.
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || {
    [ "$manifest_outside" -eq 1 ] && _checkrun_remove "$manifest"
    return "$_autolint_cancel_status"
  }
  _checkrun_registry shell-plan --output-dir "$out_dir" --phase lint \
    --files0-from "$manifest"
  plan_rc=$?
  [ "$manifest_outside" -eq 1 ] && _checkrun_remove "$manifest"
  return "$plan_rc"
}

_autolint_make_plan_dir() {
  # Allocate a caller-owned plan directory, storing the path in $1. Prefers
  # mktemp; falls back to a mkdir loop so minimal-PATH environments without
  # mktemp still plan once instead of once per file. Returns non-zero when no
  # scratch can be allocated, in which case callers keep the historical
  # per-file planning loop.
  local _varname="$1" _dir="" _i
  if command -v mktemp >/dev/null 2>&1; then
    _dir=$(mktemp -d "${TMPDIR:-/tmp}/autolint-plans.XXXXXX" 2>/dev/null) && {
      printf -v "$_varname" '%s' "$_dir"
      return 0
    }
  fi
  if command -v mkdir >/dev/null 2>&1; then
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      _dir="${TMPDIR:-/tmp}/autolint-plans.$$.${RANDOM:-0}.$_i"
      if mkdir "$_dir" 2>/dev/null; then
        # Match mktemp -d's 0700 when chmod exists; in chmod-less minimal
        # environments keep the umask-dependent dir rather than failing —
        # this fallback exists precisely for tool-poor environments.
        chmod 700 "$_dir" 2>/dev/null || true
        printf -v "$_varname" '%s' "$_dir"
        return 0
      fi
    done
  fi
  return 1
}

_autolint_remove_plan_dir() {
  # Best-effort scratch cleanup. A missing rm (minimal PATH) or a transient
  # removal failure must not rewrite the lint result already collected, so
  # cleanup status is intentionally discarded like _checkrun_remove.
  if command -v rm >/dev/null 2>&1; then
    rm -rf "$1" 2>/dev/null || true
  fi
}

_autolint_run_preplanned_sequential() {
  # Plan all files in one Python invocation, then dispatch sequentially per
  # file. Used by --fix (mutations must never run in parallel) and by the
  # minimal-PATH read-only fallback. File order, output, and exit codes match
  # the historical per-file _lint_one loop; only planner startups drop from N
  # to 1. Without allocatable scratch, degrades to that same per-file loop.
  local plan_dir="" plan_rc=0 file file_rc rc=0
  local -a files=("$@")

  [ "${#files[@]}" -eq 0 ] && return 0
  if ! _autolint_make_plan_dir plan_dir; then
    for file in "${files[@]}"; do
      if _lint_one "$file"; then
        file_rc=0
      else
        file_rc=$?
      fi
      rc=$(_autolint_merge_rc "$rc" "$file_rc")
    done
    return "$rc"
  fi
  _autolint_pre_plan "$plan_dir" "${files[@]}" || plan_rc=$?
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || {
    _autolint_remove_plan_dir "$plan_dir"
    return "$_autolint_cancel_status"
  }
  if [ "$plan_rc" -ne 0 ]; then
    _autolint_remove_plan_dir "$plan_dir"
    return "$plan_rc"
  fi
  if _autolint_run_plans_sequential "$plan_dir" "${#files[@]}"; then
    rc=0
  else
    rc=$?
  fi
  _autolint_remove_plan_dir "$plan_dir"
  return "$rc"
}

_lint_dispatch() {
  local adapter="$1" file="$2" filetype="$3" step_phase="$4" config_source="$5" config_path="$6" dir="$7"

  # Dispatch only by registry adapter id. Filetype remains available for small
  # adapter details, such as shellcheck language hints, but it no longer decides
  # whether a linter runs.
  case "$adapter" in
    actionlint) _lint_actionlint "$file" ;;
    biome-lint) _lint_biome "$file" "$dir" "$config_source" "$config_path" ;;
    buf-lint) _lint_buf "$file" "$dir" "$config_source" "$config_path" ;;
    buildifier-lint) _lint_buildifier "$file" ;;
    checkmake) _lint_checkmake "$file" "$dir" "$config_source" "$config_path" ;;
    clang-tidy) _lint_clang_tidy "$file" "$dir" "$config_source" "$config_path" ;;
    cmake-lint) _lint_cmake "$file" "$dir" "$config_source" "$config_path" ;;
    crontab) _lint_crontab "$file" ;;
    editorconfig-checker) _lint_editorconfig "$file" ;;
    git-config) _lint_git_config "$file" ;;
    google-java-format-lint) _lint_java "$file" ;;
    hadolint) _lint_dockerfile "$file" "$dir" "$config_source" "$config_path" ;;
    php) _lint_php "$file" ;;
    rubocop-lint) _lint_ruby "$file" "$dir" "$config_source" "$config_path" ;;
    ruff-lint) _lint_ruff "$file" "$dir" "$config_source" "$config_path" ;;
    rumdl-lint) _lint_rumdl "$file" "$dir" "$config_source" "$config_path" ;;
    schema-lint) _lint_schema "$file" ;;
    selene) _lint_selene "$file" "$dir" "$config_source" "$config_path" ;;
    shellcheck) _lint_sh "$file" "$dir" "$(_shellcheck_lang_hint "$file")" "$config_source" "$config_path" ;;
    statix) _lint_statix "$file" "$dir" "$config_source" "$config_path" ;;
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

_autolint_run_clean_batch_step() {
  local adapter="$1" _filetype="$2" _step_phase="$3"
  local config_source="$4" config_path="$5" start
  local -a files chunk
  shift 5
  files=("$@")

  # Bound each backend invocation while still amortizing startup. The outer
  # Sley/autolint transport retains its existing full argument list.
  for ((start = 0; start < ${#files[@]}; start += 64)); do
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
    chunk=("${files[@]:start:64}")
    case "$adapter" in
      ruff-lint)
        _lint_ruff_clean_batch "$config_source" "$config_path" "${chunk[@]}" || return 1
        ;;
      selene)
        _lint_selene_clean_batch "$config_source" "$config_path" "${chunk[@]}" || return 1
        ;;
      typos)
        _lint_typos_clean_batch "$config_source" "$config_path" "${chunk[@]}" || return 1
        ;;
      *) return 1 ;;
    esac
  done
}

_autolint_is_batchable_adapter() {
  # Single source of truth for speculative batching. ShellCheck is
  # intentionally absent: giving it multiple inputs changes
  # source-following diagnostics, so process batching is not equivalent to
  # the established independent-file checks.
  case "$1" in
    ruff-lint | selene | typos) return 0 ;;
    *) return 1 ;;
  esac
}

_autolint_flush_clean_batch_run() {
  # Run one accumulated homogeneous record run as part of the speculative
  # clean batch. The run key matches the registry grouping (adapter, config
  # source, config path); filetype and phase vary within a run and are
  # ignored by every batch backend. Stdout is discarded and stderr buffered:
  # any failure abandons the whole probe and the authoritative per-file path
  # reproduces diagnostics, so buffered output only survives when every run
  # succeeds. Returns the cancellation status when latched, else 1 on failure.
  local stderr_file="$1" adapter="$2" _filetype="$3" _step_phase="$4"
  local config_source="$5" config_path="$6"
  shift 6

  [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
  _autolint_is_batchable_adapter "$adapter" || return 1
  _autolint_run_clean_batch_step "$adapter" "$_filetype" "$_step_phase" \
    "$config_source" "$config_path" "$@" >/dev/null 2>>"$stderr_file" || return 1
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
  return 0
}

_autolint_build_residual_plans() {
  # Copy each per-file plan with batchable-adapter records removed, so the
  # speculative probe can dispatch residuals through the established per-file
  # machinery. Files with no residuals get no plan file, which the pool,
  # barrier, and sequential dispatchers all skip the same way they skip
  # empty plans.
  local plan_dir="$1" residual_dir="$2" count="$3"
  local index path filetype step_phase adapter config_source config_path

  mkdir "$residual_dir" || return 1
  index=0
  while [ "$index" -lt "$count" ]; do
    if [ -s "$plan_dir/$index.plan" ]; then
      while IFS= read -r -d '' path &&
        IFS= read -r -d '' filetype &&
        IFS= read -r -d '' step_phase &&
        IFS= read -r -d '' adapter &&
        IFS= read -r -d '' config_source &&
        IFS= read -r -d '' config_path; do
        if _autolint_is_batchable_adapter "$adapter"; then
          continue
        fi
        printf '%s\0' "$path" "$filetype" "$step_phase" \
          "$adapter" "$config_source" "$config_path" \
          >>"$residual_dir/$index.plan" || return 1
      done <"$plan_dir/$index.plan"
    fi
    index=$((index + 1))
  done
  return 0
}

_autolint_try_clean_batch() {
  local plan_dir="$1" jobs="$2" allow_parallel="$3"
  local path filetype step_phase adapter config_source config_path batch_stderr
  local residual_dir residual_stdout residual_stderr
  local run_adapter="" run_filetype="" run_phase="" run_source="" run_config=""
  local expected_count="" actual_count=0 flush_rc res_rc batch_rc start
  local residual_seen=0
  local -a files run_files
  shift 3
  files=("$@")

  [ "${#files[@]}" -gt 1 ] || return 1
  [ -s "$plan_dir/batch.plan" ] || return 1
  [ -s "$plan_dir/batch.count" ] || return 1
  command -v yq >/dev/null 2>&1 || return 1
  IFS= read -r expected_count <"$plan_dir/batch.count" || return 1
  case "$expected_count" in
    '' | *[!0-9]*) return 1 ;;
  esac

  # The manifest carries every step of every file grouped by (adapter,
  # config), so mixed sets batch per adapter group instead of abandoning the
  # probe when one file needs a non-batchable adapter. Batchable runs share
  # one backend invocation; residuals dispatch per file through the same
  # pool, barrier, or sequential path the authoritative run would use. A
  # failed probe discards all buffers and reruns the authoritative per-file
  # path so diagnostic order and attribution stay unchanged.
  batch_stderr="$plan_dir/batch.stderr"
  residual_stdout="$plan_dir/residual.stdout"
  residual_stderr="$plan_dir/residual.stderr"
  residual_dir="$plan_dir/residual"
  : >"$batch_stderr" || return 1
  run_files=()
  while IFS= read -r -d '' path &&
    IFS= read -r -d '' filetype &&
    IFS= read -r -d '' step_phase &&
    IFS= read -r -d '' adapter &&
    IFS= read -r -d '' config_source &&
    IFS= read -r -d '' config_path; do
    actual_count=$((actual_count + 1))
    if _autolint_is_batchable_adapter "$adapter"; then
      if [ "${#run_files[@]}" -gt 0 ] && {
        [ "$adapter" != "$run_adapter" ] ||
          [ "$config_source" != "$run_source" ] ||
          [ "$config_path" != "$run_config" ]
      }; then
        _autolint_flush_clean_batch_run "$batch_stderr" \
          "$run_adapter" "$run_filetype" "$run_phase" \
          "$run_source" "$run_config" "${run_files[@]}" || {
          flush_rc=$?
          rm -f "$batch_stderr"
          return "$flush_rc"
        }
        run_files=()
      fi
      if [ "${#run_files[@]}" -eq 0 ]; then
        run_adapter="$adapter"
        run_filetype="$filetype"
        run_phase="$step_phase"
        run_source="$config_source"
        run_config="$config_path"
      fi
      run_files+=("$path")
    else
      residual_seen=1
    fi
  done <"$plan_dir/batch.plan"

  if [ "${#run_files[@]}" -gt 0 ]; then
    _autolint_flush_clean_batch_run "$batch_stderr" \
      "$run_adapter" "$run_filetype" "$run_phase" \
      "$run_source" "$run_config" "${run_files[@]}" || {
      flush_rc=$?
      rm -f "$batch_stderr"
      return "$flush_rc"
    }
  fi
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || {
    rm -f "$batch_stderr"
    return "$_autolint_cancel_status"
  }
  # A short or over-long manifest must never become a silent partial lint.
  if [ "$actual_count" -ne "$expected_count" ]; then
    rm -f "$batch_stderr"
    return 1
  fi

  if [ "$residual_seen" -eq 0 ]; then
    [ -s "$batch_stderr" ] && cat "$batch_stderr" >&2
    rm -f "$batch_stderr" || true
    return 0
  fi

  if ! _autolint_build_residual_plans \
    "$plan_dir" "$residual_dir" "${#files[@]}"; then
    rm -f "$batch_stderr"
    return 1
  fi
  : >"$residual_stdout" || {
    rm -f "$batch_stderr"
    return 1
  }
  : >"$residual_stderr" || {
    rm -f "$batch_stderr" "$residual_stdout"
    return 1
  }
  if [ "$allow_parallel" -eq 1 ]; then
    if _autolint_supports_pool; then
      if _autolint_run_files_pool "$jobs" "$residual_dir" "${files[@]}" \
        >>"$residual_stdout" 2>>"$residual_stderr"; then
        res_rc=0
      else
        res_rc=$?
      fi
    else
      res_rc=0
      for ((start = 0; start < ${#files[@]}; start += jobs)); do
        [ "${_autolint_cancel_status:-0}" -eq 0 ] || break
        if _autolint_run_file_batch "$residual_dir" "$start" \
          "${files[@]:start:jobs}" >>"$residual_stdout" 2>>"$residual_stderr"; then
          batch_rc=0
        else
          batch_rc=$?
        fi
        res_rc=$(_autolint_merge_rc "$res_rc" "$batch_rc")
      done
    fi
  elif _autolint_run_plans_sequential \
    "$residual_dir" "${#files[@]}" >>"$residual_stdout" 2>>"$residual_stderr"; then
    res_rc=0
  else
    res_rc=$?
  fi
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || {
    rm -f "$batch_stderr" "$residual_stdout" "$residual_stderr"
    return "$_autolint_cancel_status"
  }
  if [ "$res_rc" -ne 0 ]; then
    rm -f "$batch_stderr" "$residual_stdout" "$residual_stderr"
    return 1
  fi
  [ -s "$batch_stderr" ] && cat "$batch_stderr" >&2
  [ -s "$residual_stdout" ] && cat "$residual_stdout"
  [ -s "$residual_stderr" ] && cat "$residual_stderr" >&2
  rm -f "$batch_stderr" "$residual_stdout" "$residual_stderr" || true
  return 0
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

  # Every file result funnels through here, including file-level statuses
  # that never reach a lint step (missing yq, planner scratch failures). A
  # status that would block as a finding is recorded before the 2-wins rule
  # below can hide it; if that record fails, report an integrity error.
  if [ "$incoming" -ne 0 ] && [ "$incoming" -ne 2 ]; then
    _autolint_note_findings || {
      printf '125\n'
      return
    }
  fi
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

_autolint_read_status_file() {
  local status_file="$1" status

  # Marker readers may race the writer between opening the file and emitting
  # its short payload. Requiring non-empty numeric content lets
  # a polling caller retry that harmless intermediate state instead of treating
  # a partially published status as a completed operation.
  [ -s "$status_file" ] || return 1
  IFS= read -r status <"$status_file" || return 1
  case "$status" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$status" -le 255 ] || return 1
  REPLY=$status
}

_autolint_run_plans_sequential() {
  local plan_dir="$1" count="$2" rc=0 file_rc index

  for ((index = 0; index < count; index++)); do
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
    [ -s "$plan_dir/$index.plan" ] || continue
    _lint_one_with_plan "$plan_dir/$index.plan"
    file_rc=$?
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
    rc=$(_autolint_merge_rc "$rc" "$file_rc")
  done
  return "$rc"
}

_autolint_reap_pids() {
  local pid
  if [ "${_autolint_cancel_status:-0}" -ne 0 ]; then
    # The first signal has already reached the entire validated group. Keep
    # later terminal-group signals from interrupting these exact waits so the
    # supervisor's exit marker means every direct worker has been reaped.
    trap '' HUP INT TERM
  fi
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done
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
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || break
    global_index=$((base_index + index))
    # Empty plans are authoritative no-ops. Do not pay for a worker and two
    # output buffers when the registry already decided this file has no lint
    # steps. Keep the original index so non-empty plan/output ordering is
    # unchanged when supported and unsupported files are interleaved.
    [ -s "$plan_dir/$global_index.plan" ] || continue
    # The plan directory is the invocation's one owned scratch root. Keeping
    # wave output here makes normal and interrupted cleanup one exact removal.
    stdout_file="$plan_dir/$global_index.stdout"
    stderr_file="$plan_dir/$global_index.stderr"
    (
      _lint_one_with_plan "$plan_dir/$global_index.plan"
    ) >"$stdout_file" 2>"$stderr_file" &
    pid=$!
    batch_pids[index]="$pid"
    batch_stdout_files[index]="$stdout_file"
    batch_stderr_files[index]="$stderr_file"
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || break
  done

  if [ "${_autolint_cancel_status:-0}" -ne 0 ]; then
    _autolint_reap_pids "${batch_pids[@]+"${batch_pids[@]}"}"
    return "$_autolint_cancel_status"
  fi

  for index in "${!batch_files[@]}"; do
    global_index=$((base_index + index))
    [ -s "$plan_dir/$global_index.plan" ] || continue
    pid=${batch_pids[$index]}
    stdout_file=${batch_stdout_files[$index]}
    stderr_file=${batch_stderr_files[$index]}
    if wait "$pid"; then
      file_rc=0
    else
      file_rc=$?
    fi
    if [ "${_autolint_cancel_status:-0}" -ne 0 ]; then
      _autolint_reap_pids "${batch_pids[@]+"${batch_pids[@]}"}"
      return "$_autolint_cancel_status"
    fi
    [ -s "$stdout_file" ] && cat "$stdout_file"
    [ -s "$stderr_file" ] && cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    rc=$(_autolint_merge_rc "$rc" "$file_rc")
  done

  return "$rc"
}

# Bash 4.3 introduced `wait -n` (wait for any one child). Older shells —
# including macOS's system bash 3.2 — must use the barrier path above. The
# modern pool uses wait-n only for backpressure; workers persist their own
# statuses because Bash needs to retain only CHILD_MAX completed-child entries and
# a sufficiently large invocation can exceed that implementation limit.
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
  # waiting for the whole wave. One slow file no longer idles the other
  # ${jobs-1} workers for the rest of the wave. Output is still emitted in
  # file_args order at the end to keep
  # diagnostics deterministic for users and editor consumers — buffering is
  # already required by the per-file output scheme.
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
  local REPLY=""

  # Spawn-and-reap loop. `wait -n` blocks until any one child finishes; its
  # exit status reflects that child but does not identify it on Bash 4.3. Each
  # worker therefore records its own status next to its buffered output. The
  # final exact waits are still required to reap owned children, but correctness
  # no longer depends on Bash retaining every earlier wait status indefinitely.
  while [ "$next" -lt "$n" ] || [ "$in_flight" -gt 0 ]; do
    while [ "$next" -lt "$n" ] && [ "$in_flight" -lt "$jobs" ]; do
      [ "${_autolint_cancel_status:-0}" -eq 0 ] || break
      if [ ! -s "$plan_dir/$next.plan" ]; then
        next=$((next + 1))
        continue
      fi
      stdout_file="$plan_dir/$next.stdout"
      stderr_file="$plan_dir/$next.stderr"
      (
        _autolint_worker_rc=0
        if _lint_one_with_plan "$plan_dir/$next.plan"; then
          _autolint_worker_rc=0
        else
          _autolint_worker_rc=$?
        fi
        # This is intentionally a shell redirection inside the invocation's
        # existing scratch root, not an external mktemp/rm pair per file. If the
        # record cannot be published, the parent maps its absence to 125 rather
        # than inventing a successful lint result.
        printf '%s\n' "$_autolint_worker_rc" >"$plan_dir/$next.status" || exit 125
        exit "$_autolint_worker_rc"
      ) >"$stdout_file" 2>"$stderr_file" &
      pids[next]=$!
      stdouts[next]=$stdout_file
      stderrs[next]=$stderr_file
      next=$((next + 1))
      in_flight=$((in_flight + 1))
      [ "${_autolint_cancel_status:-0}" -eq 0 ] || break
    done

    if [ "${_autolint_cancel_status:-0}" -ne 0 ]; then
      _autolint_reap_pids "${pids[@]+"${pids[@]}"}"
      return "$_autolint_cancel_status"
    fi

    if [ "$in_flight" -gt 0 ]; then
      # `wait -n` is only backpressure, so its status is ignored: statuses
      # come from the worker records. It can return 127 even with a child in
      # flight, when Bash already reaped that worker and dropped it from its
      # job table before this call. That worker did finish, so it still
      # leaves the in-flight count.
      wait -n 2>/dev/null || :
      if [ "${_autolint_cancel_status:-0}" -ne 0 ]; then
        _autolint_reap_pids "${pids[@]+"${pids[@]}"}"
        return "$_autolint_cancel_status"
      fi
      in_flight=$((in_flight - 1))
    fi
  done

  for i in "${!files[@]}"; do
    [ -s "$plan_dir/$i.plan" ] || continue
    # Always perform the exact wait to reap the child. Its saved status may
    # legitimately have been evicted after many later completions, so consume
    # the worker-owned record below instead of trusting a possible 127 here.
    wait "${pids[$i]}" 2>/dev/null || :
    if [ "${_autolint_cancel_status:-0}" -ne 0 ]; then
      _autolint_reap_pids "${pids[@]+"${pids[@]}"}"
      return "$_autolint_cancel_status"
    fi
    REPLY=""
    if _autolint_read_status_file "$plan_dir/$i.status"; then
      file_rc=$REPLY
    else
      file_rc=125
    fi
    [ -s "${stdouts[$i]}" ] && cat "${stdouts[$i]}"
    [ -s "${stderrs[$i]}" ] && cat "${stderrs[$i]}" >&2
    rc=$(_autolint_merge_rc "$rc" "$file_rc")
  done

  return "$rc"
}

_autolint_record_signal() {
  local status="$1"
  # The first terminal signal is the operation result. Keep both latches
  # monotonic: later delivery during cleanup must not replace the caller-facing
  # status or restart descendant cancellation with a different reason.
  [ "${_autolint_signal_status:-0}" -ne 0 ] || _autolint_signal_status=$status
  [ "${_autolint_cancel_status:-0}" -ne 0 ] || _autolint_cancel_status=$status
  # Only latch here. The supervised parent polls this latch on every iteration
  # and forwards cancellation from normal control flow, where it can first
  # prove that the supervisor still pins its private PGID. Forwarding from the
  # trap gained no latency, because Bash runs it only after the parent's
  # foreground poll command returns, but it raced a supervisor that had just
  # exited and been reaped asynchronously.
}

_autolint_restore_signal_traps() {
  local saved_hup="$1" saved_int="$2" saved_term="$3"
  # `trap -p` returns re-evaluable Bash source with the original handler safely
  # quoted. Evaluate that exact form so arbitrary caller traps survive intact;
  # an empty saved value means the caller had the default disposition.
  eval "${saved_hup:-trap - HUP}"
  eval "${saved_int:-trap - INT}"
  eval "${saved_term:-trap - TERM}"
}

_autolint_current_shell_pid() {
  local output pid extra

  if [ -n "${BASHPID:-}" ]; then
    pid=$BASHPID
  else
    # In a sourced Bash 3.2 subshell, `$$` remains the outer shell's PID even
    # though this shell owns `$!`, the job table, and the monitor-mode change.
    # A short-lived child's PPID is the portable way to identify this actual
    # shell process. `exec` is essential here: Bash 3.2 can otherwise retain
    # the command-substitution shell while it waits for `sh`, making that
    # intermediate process the reported PPID instead of this sourcing shell.
    # If `sh` is unavailable, decline supervised parallelism; using the wrong
    # PID would invalidate every later PGID safety check.
    command -v sh >/dev/null 2>&1 || return 1
    output=$(exec sh -c 'printf "%s\n" "$PPID"') || return 1
    IFS=' ' read -r pid extra <<<"$output"
    [ -z "$extra" ] || return 1
  fi
  case "$pid" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  REPLY=$pid
}

_autolint_validate_private_group() {
  local leader="$1" caller_pid="$2" jobs_file="$3" group_file="$4"
  local job_leader pid group extra
  local leader_group="" caller_group="" leader_rows=0 caller_rows=0 job_found=0
  case "$leader" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  case "$caller_pid" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  [ "$leader" != "$caller_pid" ] || return 1
  kill -0 "$leader" 2>/dev/null || return 1
  # `jobs -p` confirms that the exact unreaped `$!` is still our Bash job, but
  # some Bash/platform combinations can report `$!` even when the process is
  # still in the caller's group. Verify both real PGIDs before group signalling.
  jobs -p >|"$jobs_file" || return 1
  while IFS= read -r job_leader; do
    if [ "$job_leader" = "$leader" ]; then
      job_found=1
      break
    fi
  done <"$jobs_file"
  [ "$job_found" -eq 1 ] || return 1

  if _autolint_read_proc_group leader_group "$leader" &&
    _autolint_read_proc_group caller_group "$caller_pid"; then
    leader_rows=1
    caller_rows=1
  else
    leader_group=""
    caller_group=""
    # Linux procfs avoids a process-table fork on every multi-file hook. Other
    # platforms retain one targeted snapshot, using repeated -o fields because
    # BSD ps treats text after '=' as a header rather than another field.
    LC_ALL=C ps -o pid= -o pgid= -p "$caller_pid,$leader" \
      >"$group_file" 2>/dev/null || return 1
    while IFS=' ' read -r pid group extra; do
      [ -n "$pid" ] || continue
      [ -z "$extra" ] || return 1
      case "$pid:$group" in
        *[!0-9:]* | :* | *:) return 1 ;;
      esac
      if [ "$pid" = "$leader" ]; then
        leader_rows=$((leader_rows + 1))
        leader_group=$group
      elif [ "$pid" = "$caller_pid" ]; then
        caller_rows=$((caller_rows + 1))
        caller_group=$group
      else
        return 1
      fi
    done <"$group_file"
  fi
  [ "$leader_rows" -eq 1 ] || return 1
  [ "$caller_rows" -eq 1 ] || return 1
  [ "$leader_group" = "$leader" ] || return 1
  [ "$leader_group" != "$caller_group" ] || return 1
  REPLY=$leader_group
}

_autolint_job_is_running() {
  local leader="$1" jobs_file="$2" job_leader found=1 complete=0

  # Bash reaps an exited background job asynchronously from its SIGCHLD
  # handler, before any `wait`. After that, `kill -0` on the numeric PID is
  # meaningless: it is false, or true for an unrelated process that reused
  # it. Bash's own running-job table changes exactly when it reaps, so it is
  # the identity-safe liveness source for this exact job. `jobs` does not
  # report write errors, so on a full TMPDIR it leaves an empty file that
  # would read as "exited". Only a listing that ends in the sentinel line is
  # complete; anything else is an inspection failure.
  { jobs -pr && printf '%s\n' end; } 2>/dev/null >|"$jobs_file" || return 2
  while IFS= read -r job_leader; do
    complete=0
    case "$job_leader" in
      end) complete=1 ;;
      "$leader") found=0 ;;
    esac
  done <"$jobs_file"
  [ "$complete" -eq 1 ] || return 2
  return "$found"
}

_autolint_job_exited() {
  local rc=0
  # Only a definitive "not running" answer proves that the exact supervisor
  # left. An inspection failure must not be mistaken for exit: a holding
  # supervisor waits for the parent, so declining to stop it would deadlock.
  _autolint_job_is_running "$1" "$2" || rc=$?
  [ "$rc" -eq 1 ]
}

_autolint_read_proc_group() {
  local output_name="$1" pid="$2" stat rest state parent group extra
  case "$pid" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r stat <"/proc/$pid/stat" || return 1
  # The parenthesized comm field can itself contain spaces and `)`. Strip
  # through the final `) ` delimiter before reading state, PPID, and PGID;
  # ambiguous metadata must reject this snapshot so the caller can fall back or
  # decline group signalling instead of guessing.
  case "$stat" in
    "$pid ("*") "*) ;;
    *) return 1 ;;
  esac
  rest=${stat##*) }
  [ "$rest" != "$stat" ] || return 1
  IFS=' ' read -r state parent group extra <<<"$rest"
  [ "${#state}" -eq 1 ] || return 1
  case "$parent:$group" in
    *[!0-9:]* | :* | *:) return 1 ;;
  esac
  printf -v "$output_name" '%s' "$group"
}

_autolint_read_process_parent() {
  local pid="$1" stat rest state parent output extra
  case "$pid" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac

  if [ -r "/proc/$pid/stat" ]; then
    IFS= read -r stat <"/proc/$pid/stat" || return 1
    # Match the rightmost comm delimiter for the same reason as the PGID reader.
    # Parent identity controls when an anchored PGID may be released, so a
    # surprising process name must fail closed rather than shift the PPID field.
    case "$stat" in
      "$pid ("*") "*) ;;
      *) return 1 ;;
    esac
    rest=${stat##*) }
    [ "$rest" != "$stat" ] || return 1
    IFS=' ' read -r state parent _ <<<"$rest"
    [ "${#state}" -eq 1 ] || return 1
  else
    # BSD/macOS have no procfs, so use the same portable ps capability that
    # validation relies on. This query runs only while the leader holds its
    # identity, and only after its first fast polls. An unvalidated candidate
    # can hold on a host where ps fails too; its caller then falls back to a
    # parent liveness probe.
    output=$(LC_ALL=C ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    IFS=' ' read -r parent extra <<<"$output"
    [ -z "$extra" ] || return 1
  fi
  case "$parent" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  REPLY=$parent
}

_autolint_supervisor_quiesced() {
  local busy_file="$1" exited_file="$2"
  # Either marker means the supervisor's EXIT handler ran and it is holding
  # its identity for the parent: busy empties on completion, and exited
  # carries the status of a cancellation.
  [ ! -s "$busy_file" ] || [ -s "$exited_file" ]
}

_autolint_unhold() {
  # Emptying hold lets a holding supervisor exit, and makes one still in its
  # gate wait abort. Callers do this only after their last signal, right
  # before exact wait, so that wait also ends if the job table misreported a
  # live supervisor as exited.
  : 2>/dev/null >|"$1" || :
}

_autolint_release_supervisor() {
  local leader="$1" target="$2" hold_file="$3" jobs_file="$4"
  # The supervisor exits only after this marker empties, so clearing it is the
  # last parent action before exact wait; no signal may follow it. Truncation
  # is a builtin that allocates nothing, but if it still fails the supervisor
  # keeps holding. Its identity is then still pinned, and KILL is the only way
  # to avoid an unbounded wait. Return failure so a caller can report the lost
  # status.
  _autolint_unhold "$hold_file"
  [ -s "$hold_file" ] || return 0
  if ! _autolint_job_exited "$leader" "$jobs_file"; then
    kill -KILL "$target" 2>/dev/null || true
  fi
  return 1
}

_autolint_await_armed() {
  local leader="$1" armed_file="$2" jobs_file="$3" attempt
  # A subshell starts with the parent's caught signals reset to their default
  # action, so a TERM that lands before the supervisor installs its latches
  # is never recorded as a cancellation. Before its EXIT trap exists it kills
  # the supervisor outright, leaving no hold; after that, the trap runs as if
  # the work had completed. The supervisor publishes this marker right after
  # installing its latches. It normally exists before the parent finishes
  # validation; the bound covers a stalled or unwritable one. Status 1 means
  # the job already left Bash's running set, so its PID must not be signalled;
  # status 2 means the wait expired.
  for ((attempt = 0; attempt < 200; attempt++)); do
    [ -e "$armed_file" ] && return 0
    _autolint_job_exited "$leader" "$jobs_file" && return 1
    if [ "$attempt" -lt 20 ]; then
      sleep 0.001 || :
    else
      sleep 0.01 || :
    fi
  done
  return 2
}

_autolint_stop_unvalidated_leader() {
  local leader="$1" busy_file="$2" exited_file="$3" hold_file="$4"
  local jobs_file="$5" armed_file="$6" attempt armed_rc=0
  case "$leader" in
    '' | 0 | *[!0-9]*) return 0 ;;
  esac
  # The gate is still closed, so this exact Bash job cannot own planners or
  # workers yet, and its group identity has not been proved safe to signal.
  # Stop only the captured child PID. Before the gate the supervisor leaves
  # its wait only on a signal or parent death, and then holds its PID until
  # released. A job still in Bash's running set is therefore pinned, and one
  # that already left it is never signalled again: its PID may be reused.
  # Waiting for an unarmed supervisor usually costs one more poll and keeps
  # this TERM from landing on the default action. An empty marker path means
  # the caller already let that bounded wait expire. A supervisor that never
  # arms is still TERMed; one that left the running set meanwhile is not.
  if [ -n "$armed_file" ]; then
    _autolint_await_armed "$leader" "$armed_file" "$jobs_file" || armed_rc=$?
  fi
  if [ "$armed_rc" -ne 1 ] &&
    ! _autolint_job_exited "$leader" "$jobs_file"; then
    kill -TERM "$leader" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
      _autolint_supervisor_quiesced "$busy_file" "$exited_file" && break
      _autolint_job_exited "$leader" "$jobs_file" && break
      sleep 0.01
    done
    if _autolint_supervisor_quiesced "$busy_file" "$exited_file"; then
      _autolint_release_supervisor \
        "$leader" "$leader" "$hold_file" "$jobs_file" || :
    elif ! _autolint_job_exited "$leader" "$jobs_file"; then
      # The supervisor never armed, or could not write its exited marker.
      # Neither releases the PID, so this KILL still reaches the exact child.
      kill -KILL "$leader" 2>/dev/null || true
    fi
  fi
  # Exact wait reaps the child so fallback cannot inherit an orphan or zombie.
  _autolint_unhold "$hold_file"
  wait "$leader" 2>/dev/null || true
}

_autolint_cancel_private_group() {
  local leader="$1" group="$2" busy_file="$3" exited_file="$4"
  local hold_file="$5" jobs_file="$6"
  local attempt signals_frozen=0

  if [ "${_autolint_signal_status:-0}" -ne 0 ] ||
    [ "${_autolint_cancel_status:-0}" -ne 0 ]; then
    # A cancellation is already authoritative. Ignore later terminal-group
    # delivery while exact cleanup runs so it cannot replace or interrupt the
    # first result.
    trap '' HUP INT TERM
    signals_frozen=1
  fi
  # After the gate, the supervisor exits only once released, on parent death,
  # or by the KILL below. A job still in Bash's running set therefore pins the
  # private PGID. One that already left it (an external KILL, or a completion
  # marker it could not publish) has released that number, so it is reaped
  # without any group signal.
  if [ ! -s "$busy_file" ] || _autolint_job_exited "$leader" "$jobs_file"; then
    # Normal completion already quiesced every worker; release the anchor only.
    _autolint_release_supervisor \
      "$leader" "-$group" "$hold_file" "$jobs_file" || :
    wait "$leader" 2>/dev/null || true
    return 0
  fi
  kill -TERM "-$group" 2>/dev/null || true
  # On cancellation, the supervisor reaps every exact worker, publishes
  # exited, and then remains alive as the private group's PID anchor. Give
  # cooperative cleanup a short grace before escalating the still-pinned
  # group; no process-table scan or reusable bare PGID is involved.
  for ((attempt = 0; attempt < 20; attempt++)); do
    if [ "$signals_frozen" -eq 0 ] &&
      { [ "${_autolint_signal_status:-0}" -ne 0 ] ||
        [ "${_autolint_cancel_status:-0}" -ne 0 ]; }; then
      # Capability cleanup can enter here before any user cancellation exists.
      # Keep the managed handlers live until that first signal is latched, then
      # freeze only subsequent delivery for the remainder of the exact reap.
      trap '' HUP INT TERM
      signals_frozen=1
    fi
    _autolint_supervisor_quiesced "$busy_file" "$exited_file" && break
    _autolint_job_exited "$leader" "$jobs_file" && break
    sleep 0.01
  done
  if [ "$signals_frozen" -eq 0 ] &&
    { [ "${_autolint_signal_status:-0}" -ne 0 ] ||
      [ "${_autolint_cancel_status:-0}" -ne 0 ]; }; then
    trap '' HUP INT TERM
  fi
  if [ ! -s "$busy_file" ]; then
    # The supervisor completed normally during the grace and is holding.
    _autolint_release_supervisor \
      "$leader" "-$group" "$hold_file" "$jobs_file" || :
  elif ! _autolint_job_exited "$leader" "$jobs_file"; then
    # Still pinned: KILL the complete group, which ends the anchor together
    # with any straggler that ignored the cooperative TERM.
    kill -KILL "-$group" 2>/dev/null || true
  fi
  _autolint_unhold "$hold_file"
  wait "$leader" 2>/dev/null || true
}

_autolint_hold_pause() {
  # Every successful run now ends with this hold, and the parent normally
  # releases it within one of its own 10 ms polls. Poll finely at first so
  # that handshake stays cheap, then back off so a stopped (for example,
  # Ctrl-Z) parent cannot make the anchor spin: 100 ms after about a second,
  # and 1 s after about five. Each poll forks `sleep`, and on hosts without
  # procfs also `ps`, so a commit left suspended for hours costs one of each
  # per second. A parent that resumes after that long waits at most one more
  # second for the release. The counter is the caller's dynamically scoped
  # local.
  _autolint_hold_polls=$((${_autolint_hold_polls:-0} + 1))
  # EXIT trap actions run with errexit active under a `set -e` caller, so a
  # failed sleep must not abort the hold and release the identity.
  if [ "$_autolint_hold_polls" -le 20 ]; then
    sleep 0.001 || :
  elif [ "$_autolint_hold_polls" -le 120 ]; then
    sleep 0.01 || :
  elif [ "$_autolint_hold_polls" -le 160 ]; then
    sleep 0.1 || :
  else
    sleep 1 || :
  fi
}

_autolint_finish_parallel_supervisor() {
  local parent_pid="$1" busy_file="$2" hold_file="$3" exited_file="$4"
  local leader_file="$5" leader="" REPLY="" _autolint_hold_polls=0

  if [ "${_autolint_cancel_status:-0}" -eq 0 ]; then
    # Publish completion by emptying a marker the parent precreated. Truncation
    # allocates nothing, so unlike creating a file a full TMPDIR cannot hide
    # completion. The marker is a synchronization hint; the lint status still
    # comes from the parent's exact wait.
    : 2>/dev/null >|"$busy_file" || :
    # Only outside interference can leave the marker in place. Holding would
    # then make the parent wait forever for a completion it cannot observe, so
    # exit; the parent sees this exact job leave Bash's running set and never
    # signals the released identity.
    [ ! -s "$busy_file" ] || return 0
  else
    # Publish the cancellation reason before becoming an identity anchor. The
    # parent has its own signal latch for ordinary parent-directed
    # cancellation, so marker failure still degrades to bounded group cleanup
    # in that path. A valid record additionally covers a signal delivered
    # directly to the group.
    printf '%s\n' "$_autolint_cancel_status" 2>/dev/null >"$exited_file" || true
  fi

  # Keep the exact PID, and with it the private PGID, allocated until the
  # parent removes the hold marker. Bash reaps an exited background job
  # asynchronously, so once this process exits both numbers can be reused
  # before the parent's next instruction; while it holds, every parent signal
  # reaches an identity that cannot have been reused. This also covers the
  # time before gate release, when the parent signals this exact PID. A
  # wall-clock deadline is unsafe: the parent can be SIGSTOPed past it and
  # later resume with a now-reusable number.
  trap '' HUP INT TERM

  # Bash 3.2 has no BASHPID, so the parent also publishes this exact PID.
  leader=${BASHPID:-}
  while [ -z "$leader" ]; do
    [ -s "$hold_file" ] || return 0
    if IFS= read -r leader 2>/dev/null <"$leader_file"; then
      case "$leader" in
        '' | 0 | *[!0-9]*) leader="" ;;
        *) break ;;
      esac
    fi
    leader=""
    # Without the leader marker this process cannot prove its parent link.
    # A failed probe still proves the parent is gone (ESRCH, or EPERM after
    # reuse by another user), and only that parent ever signals this group.
    # Success is inconclusive, so keep holding rather than release a PGID the
    # parent may still target.
    kill -0 "$parent_pid" 2>/dev/null || return 0
    _autolint_hold_pause
  done
  while :; do
    [ -s "$hold_file" ] || return 0
    # The parent normally releases a completed run within its first few fast
    # polls. Defer the parent probe until then: on hosts without procfs it
    # forks ps, which every successful run would otherwise pay.
    if [ "$_autolint_hold_polls" -lt 20 ]; then
      _autolint_hold_pause
      continue
    fi
    REPLY=""
    if _autolint_read_process_parent "$leader"; then
      # PPID identity is stronger than `kill -0 parent_pid`: after reparenting,
      # PID reuse cannot make this exact child belong to an unrelated process.
      [ "$REPLY" = "$parent_pid" ] || return 0
    fi
    # A failed PPID read is not evidence that releasing the PGID is safe, but
    # a failed parent probe is (see above). Otherwise keep holding: parent
    # death reparents this live child, and a later read returns a definitive
    # different PPID.
    if [ -z "$REPLY" ]; then
      kill -0 "$parent_pid" 2>/dev/null || return 0
    fi
    _autolint_hold_pause
  done
}

_autolint_count_nonempty_plans() {
  local plan_dir="$1" count="$2" index nonempty=0
  for ((index = 0; index < count; index++)); do
    [ -s "$plan_dir/$index.plan" ] && nonempty=$((nonempty + 1))
  done
  REPLY=$nonempty
}

_autolint_run_read_only_pipeline() {
  local plan_dir="$1" jobs="$2" allow_parallel="$3"
  shift 3
  local plan_rc=0 nonempty=0 run_rc=0 REPLY=""
  local -a files=("$@")

  [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
  _autolint_pre_plan "$plan_dir" "${files[@]}" || plan_rc=$?
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
  [ "$plan_rc" -eq 0 ] || return "$plan_rc"

  if [ "$json" -eq 0 ]; then
    if _autolint_try_clean_batch \
      "$plan_dir" "$jobs" "$allow_parallel" "${files[@]}"; then
      return 0
    fi
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
  fi

  if [ "$allow_parallel" -eq 1 ]; then
    _autolint_count_nonempty_plans "$plan_dir" "${#files[@]}"
    nonempty=$REPLY
    if [ "$nonempty" -gt 1 ]; then
      if _autolint_supports_pool; then
        _autolint_run_files_pool "$jobs" "$plan_dir" "${files[@]}"
        return $?
      fi
      local start batch_rc rc=0
      for ((start = 0; start < ${#files[@]}; start += jobs)); do
        [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
        if _autolint_run_file_batch \
          "$plan_dir" "$start" "${files[@]:start:jobs}"; then
          batch_rc=0
        else
          batch_rc=$?
        fi
        rc=$(_autolint_merge_rc "$rc" "$batch_rc")
      done
      return "$rc"
    fi
  fi

  if _autolint_run_plans_sequential "$plan_dir" "${#files[@]}"; then
    run_rc=0
  else
    run_rc=$?
  fi
  return "$run_rc"
}

_autolint_run_direct_read_only_fallback() {
  local jobs="$1"
  shift
  local plan_dir="" allocation_rc=0 run_rc=0 cleanup_rc=0 file_rc=0 rc=0 file
  local -a files=("$@")

  # A host without procfs/ps cannot prove a private process group, but that is
  # only a limit on parallel cancellation. Keep foreground planning batched so
  # a 300-file hook does not regress from one registry interpreter to 300. Use
  # fresh scratch after the managed candidate has been reaped and cleaned: this
  # path runs under the caller's restored traps and owns no background workers.
  plan_dir=$(mktemp -d "${TMPDIR:-/tmp}/autolint-plans.XXXXXX") || allocation_rc=125
  if [ "$allocation_rc" -ne 0 ]; then
    # Directory allocation is the one environment where batched planning is
    # impossible. Retain the historical tempfile-per-file escape hatch so a
    # transient capability failure does not silently skip linting.
    for file in "${files[@]}"; do
      if _lint_one "$file"; then
        file_rc=0
      else
        file_rc=$?
      fi
      rc=$(_autolint_merge_rc "$rc" "$file_rc")
    done
    return "$rc"
  fi

  if _autolint_run_read_only_pipeline \
    "$plan_dir" "$jobs" 0 "${files[@]}"; then
    run_rc=0
  else
    run_rc=$?
  fi

  # The direct fallback has no signal latch to protect a retry, so make both
  # attempts explicit and bounded. A retained directory is a plumbing failure,
  # but it must not erase the lint result that was already collected above.
  if rm -rf "$plan_dir"; then
    cleanup_rc=0
  else
    cleanup_rc=$?
  fi
  if [ -e "$plan_dir" ]; then
    if rm -rf "$plan_dir"; then
      cleanup_rc=0
    else
      cleanup_rc=$?
    fi
  fi
  if [ -e "$plan_dir" ]; then
    echo "autolint: could not remove registry plan temp directory" >&2
    cleanup_rc=125
  else
    cleanup_rc=0
  fi

  rc=$(_autolint_merge_rc "$run_rc" "$cleanup_rc")
  return "$rc"
}

_autolint_parallel_supervisor() {
  local gate="$1" armed_file="$2" hold_file="$3" parent_pid="$4" jobs="$5"
  local plan_dir="$6"
  shift 6
  local rc=0 _autolint_signal_status=0
  local -a files=("$@")

  # Install handlers before observing the gate so cancellation cannot be lost
  # during parent-side validation. The directory is the authority to begin
  # work; before it exists, parent liveness only prevents a stranded candidate
  # and does not authorize this child to create descendants.
  trap '_autolint_record_signal 129' HUP
  trap '_autolint_record_signal 130' INT
  trap '_autolint_record_signal 143' TERM
  # From here a parent TERM is latched rather than fatal. A failed write only
  # delays the parent's bounded wait and then falls back to sequential lint.
  : 2>/dev/null >"$armed_file" || :
  while [ ! -d "$gate" ]; do
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
    # An emptied hold before the gate is the parent's signal-free abort.
    [ -s "$hold_file" ] || return 125
    kill -0 "$parent_pid" 2>/dev/null || return 125
    sleep 0.001
  done
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"

  if _autolint_run_read_only_pipeline \
    "$plan_dir" "$jobs" 1 "${files[@]}"; then
    rc=0
  else
    rc=$?
  fi
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || rc=$_autolint_cancel_status
  return "$rc"
}

_autolint_restore_monitor() {
  [ "$1" -eq 0 ] || set -m 2>/dev/null || true
}

_autolint_run_parallel_supervised() {
  local jobs="$1" plan_dir="$2"
  shift 2
  local control_dir="$plan_dir/.supervisor" gate busy_file hold_file exited_file
  local armed_file jobs_file group_file leader_file
  local parent_pid="" leader="" group="" rc=0 tool event_status=0 job_state=0
  local had_monitor=0 released=1 armed_rc=0
  local REPLY=""

  # Until this function sets `_autolint_parallel_validated`, a zero return means
  # the host could not safely provide supervised cancellation, not that linting
  # completed. The caller uses the flag to clean up, restore its traps, and run
  # the foreground fallback outside this managed scope.
  _autolint_parallel_validated=0
  [ "${_autolint_signal_status:-0}" -eq 0 ] || return "$_autolint_signal_status"
  for tool in mkdir sleep; do
    command -v "$tool" >/dev/null 2>&1 || return 0
  done
  if ! _autolint_current_shell_pid; then
    return 0
  fi
  parent_pid=$REPLY
  mkdir "$control_dir" 2>/dev/null || return 0
  gate="$control_dir/gate"
  busy_file="$control_dir/busy"
  hold_file="$control_dir/hold"
  exited_file="$control_dir/exited"
  armed_file="$control_dir/armed"
  jobs_file="$control_dir/jobs"
  group_file="$control_dir/groups"
  leader_file="$control_dir/leader"
  # Both lifecycle markers are written before the supervisor exists, so each
  # side signals the other by truncating one: a fork-free builtin that needs
  # no new allocation, unlike creating a file on a full TMPDIR. The supervisor
  # empties busy on normal completion; the parent empties hold once it will
  # never signal the supervisor's PID or PGID again.
  printf '1\n' 2>/dev/null >|"$busy_file" || return 0
  printf '1\n' 2>/dev/null >|"$hold_file" || return 0

  [[ "$-" == *m* ]] && had_monitor=1
  if ! set -m 2>/dev/null; then
    return 0
  fi
  (
    # Parent monitor mode exists only to create this one private process group.
    # Disable it in the supervisor so every planner and worker inherits that
    # validated PGID and one group signal covers the complete descendant tree.
    set +m
    # A sourced caller may own an EXIT trap, but this child must publish only its
    # supervisor lifecycle markers. Replace any inherited EXIT behavior before
    # installing the anchor-aware handler below.
    trap - EXIT
    # shellcheck disable=SC2030 # This reset intentionally belongs only to the supervisor copy.
    _autolint_cancel_status=0
    # The EXIT handler publishes completion or the cancellation status, then
    # holds this exact PID and PGID until the parent releases them, so no
    # parent signal can reach a reused identity.
    trap '_autolint_finish_parallel_supervisor "$parent_pid" "$busy_file" "$hold_file" "$exited_file" "$leader_file"' EXIT
    _autolint_parallel_supervisor \
      "$gate" "$armed_file" "$hold_file" "$parent_pid" "$jobs" "$plan_dir" "$@"
  ) </dev/null &
  leader=$!
  # `$!` is captured while monitor mode creates the private candidate group.
  # Disable monitor mode immediately afterward, before any fallible marker I/O,
  # so a monitor-off sourcing caller cannot receive an asynchronous `[1]+ Done`
  # notification on an early-return path.
  set +m
  # The child needs this exact leader to prove that it still belongs to this
  # parent while holding the PGID. Failure occurs before gate release, so stop
  # and reap only the exact unvalidated child rather than guessing at a group.
  if ! printf '%s\n' "$leader" 2>/dev/null >"$leader_file"; then
    _autolint_stop_unvalidated_leader \
      "$leader" "$busy_file" "$exited_file" "$hold_file" "$jobs_file" \
      "$armed_file"
    _autolint_restore_monitor "$had_monitor"
    return 0
  fi
  # The gated leader is intended to own a private group; validation below is
  # authoritative. Keep notifications disabled through validation, polling,
  # and exact wait. Restoring `m` only after reaping avoids a late `[1]+ Done`
  # diagnostic for callers that originally enabled monitor mode.

  if [ "${_autolint_signal_status:-0}" -ne 0 ]; then
    _autolint_stop_unvalidated_leader \
      "$leader" "$busy_file" "$exited_file" "$hold_file" "$jobs_file" \
      "$armed_file"
    _autolint_restore_monitor "$had_monitor"
    return "$_autolint_signal_status"
  fi
  if ! _autolint_validate_private_group \
    "$leader" "$parent_pid" "$jobs_file" "$group_file"; then
    _autolint_stop_unvalidated_leader \
      "$leader" "$busy_file" "$exited_file" "$hold_file" "$jobs_file" \
      "$armed_file"
    _autolint_restore_monitor "$had_monitor"
    return 0
  fi
  group=$REPLY
  # With the gate still closed, a signal latched during validation, a leader
  # that is already gone, or one that never armed needs only exact-PID
  # cleanup: no planner or worker can exist yet, so a group signal would add
  # identity risk and clean nothing. Opening the gate only to an armed
  # supervisor means every later group TERM is latched by its handlers rather
  # than killing the identity anchor outright.
  armed_rc=0
  if [ "${_autolint_signal_status:-0}" -eq 0 ]; then
    _autolint_await_armed "$leader" "$armed_file" "$jobs_file" || armed_rc=$?
  fi
  if [ "${_autolint_signal_status:-0}" -ne 0 ] || [ "$armed_rc" -ne 0 ] ||
    _autolint_job_exited "$leader" "$jobs_file"; then
    # An arming wait that already expired need not run a second time.
    [ "$armed_rc" -ne 2 ] || armed_file=""
    _autolint_stop_unvalidated_leader \
      "$leader" "$busy_file" "$exited_file" "$hold_file" "$jobs_file" \
      "$armed_file"
    _autolint_restore_monitor "$had_monitor"
    return "${_autolint_signal_status:-0}"
  fi
  # Directory creation is the nonblocking gate release. Unlike opening a FIFO
  # writer, it cannot hang if the validated child exits at this boundary.
  if ! mkdir "$gate" 2>/dev/null; then
    if [ -d "$gate" ]; then
      # `mkdir` can create the directory and still report interruption/failure.
      # Gate visibility authorizes work, so once visible the already-validated
      # group is the only complete cancellation boundary.
      _autolint_cancel_private_group "$leader" "$group" \
        "$busy_file" "$exited_file" "$hold_file" "$jobs_file"
      # Group cleanup shields terminal signals. Re-arm the managed handlers so
      # a later signal during scratch cleanup is still latched by the parent.
      trap '_autolint_record_signal 129' HUP
      trap '_autolint_record_signal 130' INT
      trap '_autolint_record_signal 143' TERM
    else
      # With no visible gate, the supervisor cannot have started a planner or
      # worker. Stop and reap only the exact child PID; signalling its PGID here
      # would add identity risk without any descendants to clean.
      _autolint_stop_unvalidated_leader \
        "$leader" "$busy_file" "$exited_file" "$hold_file" "$jobs_file" \
        "$armed_file"
    fi
    _autolint_restore_monitor "$had_monitor"
    return 0
  fi
  _autolint_parallel_validated=1

  # Do not jump directly from the final latch check into a blocking wait. A
  # signal in that instruction-sized gap can make the child hold its identity
  # while the already-run parent trap has no second event to interrupt wait.
  # Poll only invocation-owned state plus Bash's exact job table; this removes
  # any need for the child to re-signal a possibly reused numeric parent PID.
  while :; do
    if [ "${_autolint_signal_status:-0}" -ne 0 ]; then
      _autolint_cancel_private_group "$leader" "$group" \
        "$busy_file" "$exited_file" "$hold_file" "$jobs_file"
      _autolint_restore_monitor "$had_monitor"
      return "$_autolint_signal_status"
    fi

    REPLY=""
    if _autolint_read_status_file "$exited_file"; then
      case "$REPLY" in
        129 | 130 | 143) event_status=$REPLY ;;
        *) event_status=0 ;;
      esac
      if [ "$event_status" -ne 0 ]; then
        # A direct group signal can reach the supervisor without first running
        # the parent's trap. Import that already-published first status before
        # cleanup so later terminal delivery cannot replace it.
        [ "${_autolint_signal_status:-0}" -ne 0 ] ||
          _autolint_signal_status=$event_status
        # ShellCheck pairs this parent read with the supervisor's subshell-local
        # reset above. They are intentionally separate dynamic-scope copies.
        # shellcheck disable=SC2031
        if [ "${_autolint_cancel_status:-0}" -eq 0 ]; then
          _autolint_cancel_status=$event_status
        fi
        _autolint_cancel_private_group "$leader" "$group" \
          "$busy_file" "$exited_file" "$hold_file" "$jobs_file"
        _autolint_restore_monitor "$had_monitor"
        return "$_autolint_signal_status"
      fi
    fi

    if [ ! -s "$busy_file" ]; then
      # Normal completion: the supervisor quiesced its workers and now holds
      # its identity. Releasing it is the final parent action on that
      # identity; nothing below may signal it.
      _autolint_release_supervisor \
        "$leader" "-$group" "$hold_file" "$jobs_file" || released=0
      break
    fi
    if _autolint_job_is_running "$leader" "$jobs_file"; then
      job_state=0
    else
      job_state=$?
      # Status 1 means the exact job left Bash's running set without
      # publishing completion, so its PID and PGID may already be reused and
      # are never signalled again. Status 2 is only an inspection failure;
      # the supervisor still holds, so retry owned markers instead.
      if [ "$job_state" -eq 1 ]; then
        _autolint_unhold "$hold_file"
        break
      fi
    fi
    sleep 0.01
  done

  # Bash reports a KILLed job from inside wait; the status below suffices.
  if wait "$leader" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  # A release that needed KILL lost the supervisor's real exit status.
  [ "$released" -eq 1 ] || rc=125
  if [ "${_autolint_signal_status:-0}" -ne 0 ]; then
    # The supervisor finished its work, or the job table reported it gone, so
    # its identity is no longer pinned and is never signalled. In the second
    # case only, a lint still running is not cancelled and this wait lasts
    # until it ends. A trap interrupts Bash's wait without reaping the direct
    # child, so wait once more with later delivery shielded.
    trap '' HUP INT TERM
    wait "$leader" 2>/dev/null || true
    _autolint_restore_monitor "$had_monitor"
    return "$_autolint_signal_status"
  fi
  _autolint_restore_monitor "$had_monitor"
  return "$rc"
}

_autolint_run() {
  local fix=0 json=0 rc=0 jobs file lint_file arg
  local files0_from="" files0_seen=0 parse_options=1 _autolint_force_manifest=0
  local -a file_args=() lint_files=() _autolint_files0_args=()

  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    if [ "$parse_options" -eq 0 ]; then
      file_args+=("$arg")
      continue
    fi
    case "$arg" in
      --) parse_options=0 ;;
      --fix) fix=1 ;;
      --json) json=1 ;;
      --files0-from)
        if [ "$files0_seen" -eq 1 ]; then
          echo "autolint: --files0-from may be provided only once" >&2
          return 2
        fi
        if [ "$#" -eq 0 ]; then
          echo "autolint: --files0-from requires a file" >&2
          return 2
        fi
        files0_from=$1
        files0_seen=1
        shift
        ;;
      --files0-from=*)
        if [ "$files0_seen" -eq 1 ]; then
          echo "autolint: --files0-from may be provided only once" >&2
          return 2
        fi
        files0_from=${arg#*=}
        files0_seen=1
        [ -n "$files0_from" ] || {
          echo "autolint: --files0-from requires a file" >&2
          return 2
        }
        ;;
      -h | --help)
        _autolint_usage
        return 0
        ;;
      -*)
        if [ -f "$arg" ]; then
          # Before this parser grew manifest support, option-shaped existing
          # paths were ordinary file arguments. Preserve that compatibility;
          # only unknown non-files are usage errors.
          file_args+=("$arg")
        else
          echo "autolint: unknown option: $arg" >&2
          return 2
        fi
        ;;
      *) file_args+=("$arg") ;;
    esac
  done

  if [ "$files0_seen" -eq 1 ] && [ "${#file_args[@]}" -ne 0 ]; then
    echo "autolint: --files0-from cannot be combined with positional files" >&2
    return 2
  fi
  if [ "$files0_seen" -eq 1 ]; then
    if [ "$files0_from" != "-" ] &&
      { [ ! -f "$files0_from" ] || [ ! -r "$files0_from" ]; }; then
      echo "autolint: --files0-from requires a readable regular file: $files0_from" >&2
      return 2
    fi
    if [ "$files0_from" = "-" ]; then
      _autolint_read_files0 "$files0_from"
    else
      # shellcheck disable=SC2094 # The helper only reads stdin; it never writes the source path.
      _autolint_read_files0 "$files0_from" <"$files0_from"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
      return "$rc"
    fi
    file_args+=(${_autolint_files0_args[@]+"${_autolint_files0_args[@]}"})
  fi
  # A manifest-backed caller may have a large inherited environment even when
  # the decoded path payload is below the ordinary argv threshold. Keep the
  # second planner boundary manifest-backed unconditionally in that mode.
  _autolint_force_manifest=$files0_seen

  [ "${#file_args[@]}" -eq 0 ] && return 0

  for file in "${file_args[@]}"; do
    if _lintable_path_into lint_file "$file"; then
      lint_files+=("$lint_file")
    fi
  done

  if [ "${#lint_files[@]}" -eq 0 ]; then
    # No registry planner will run, so retain the direct CLI's historical path
    # policy validation without adding a duplicate interpreter to real files.
    _checkrun_config_dir >/dev/null || return
    return 0
  fi

  if [ "$fix" -eq 1 ]; then
    # Keep mutation mode sequential. Several backends operate at package/project
    # scope even when they receive one file, so parallel fixes can race on shared
    # source files or tool caches. Read-only linting below is safe to overlap.
    # Planning happens once for all files; only per-file dispatch stays
    # sequential, preserving the no-parallel-mutation invariant.
    _autolint_run_preplanned_sequential "${lint_files[@]}"
    rc=$(_autolint_merge_rc "$rc" "$?")
  else
    jobs=${CHECKRUN_AUTOLINT_JOBS:-$(_autolint_default_jobs)}
    case "$jobs" in
      '' | *[!0-9]*) jobs=1 ;;
    esac
    [ "$jobs" -lt 1 ] && jobs=1
    if ! command -v mktemp >/dev/null 2>&1 ||
      ! command -v cat >/dev/null 2>&1 ||
      ! command -v rm >/dev/null 2>&1; then
      # Tests and minimal hook environments sometimes constrain PATH to only the
      # backend being exercised. In that mode correctness is more important than
      # concurrency, so fall back to sequential pre-planned dispatch, which
      # degrades to the historical per-file loop only when no planner scratch
      # can be allocated at all.
      _autolint_run_preplanned_sequential "${lint_files[@]}"
      rc=$(_autolint_merge_rc "$rc" "$?")
    else
      # A multi-input/jobs>1 operation cannot know how many plans are nonempty
      # until the registry returns, so its validated group owns the complete
      # planner-through-linter pipeline. One-file and jobs=1 calls retain their
      # direct signal behavior without installing managed cancellation traps.
      local plan_dir="" allocation_rc=0 run_rc=0 file_rc=0 cleanup_rc=0
      local cleanup_signals_frozen=0
      local managed_parallel=0 direct_fallback=0
      local saved_hup saved_int saved_term
      local _autolint_signal_status=0 _autolint_cancel_status=0
      local _autolint_parallel_validated=0

      if [ "$jobs" -gt 1 ] && [ "${#lint_files[@]}" -gt 1 ]; then
        managed_parallel=1
        # Managed semantics begin before scratch allocation: a signal during
        # mktemp, validation, or cleanup must be latched as the operation result,
        # and fallback must not run until the exact caller traps are restored.
        saved_hup=$(trap -p HUP)
        saved_int=$(trap -p INT)
        saved_term=$(trap -p TERM)
        trap '_autolint_record_signal 129' HUP
        trap '_autolint_record_signal 130' INT
        trap '_autolint_record_signal 143' TERM
      fi
      plan_dir=$(mktemp -d "${TMPDIR:-/tmp}/autolint-plans.XXXXXX") || allocation_rc=125
      if [ "$allocation_rc" -eq 0 ]; then
        if [ "$managed_parallel" -eq 1 ]; then
          if [ "$_autolint_signal_status" -eq 0 ]; then
            if _autolint_run_parallel_supervised \
              "$jobs" "$plan_dir" "${lint_files[@]}"; then
              run_rc=0
            else
              run_rc=$?
            fi
            if [ "$_autolint_signal_status" -ne 0 ]; then
              rc=$_autolint_signal_status
            elif [ "$_autolint_parallel_validated" -eq 1 ]; then
              rc=$(_autolint_merge_rc "$rc" "$run_rc")
            else
              # Restricted hosts retain the historical direct sequential path,
              # but only after this managed scope removes its plan root and
              # restores the caller's signal semantics. Do not run foreground
              # fallback work under latch traps that cannot own descendants.
              direct_fallback=1
            fi
          fi
        else
          if _autolint_run_read_only_pipeline \
            "$plan_dir" "$jobs" 0 "${lint_files[@]}"; then
            run_rc=0
          else
            run_rc=$?
          fi
          rc=$(_autolint_merge_rc "$rc" "$run_rc")
        fi

        if rm -rf "$plan_dir"; then
          cleanup_rc=0
        else
          cleanup_rc=$?
        fi
        if [ "$managed_parallel" -eq 1 ] &&
          [ "$_autolint_signal_status" -ne 0 ]; then
          # Once the first signal is latched, shield the exact cleanup retry
          # from later terminal-group delivery. With no latched signal, keep
          # the handlers active so cancellation during an ordinary retry is
          # recorded rather than silently ignored.
          trap '' HUP INT TERM
          cleanup_signals_frozen=1
        fi
        if [ -e "$plan_dir" ]; then
          if rm -rf "$plan_dir"; then
            cleanup_rc=0
          else
            cleanup_rc=$?
          fi
        fi
        if [ "$managed_parallel" -eq 1 ] &&
          [ "$_autolint_signal_status" -ne 0 ] &&
          [ "$cleanup_signals_frozen" -eq 0 ]; then
          # The retry itself observed the first signal. Freeze only now, then
          # make one final protected attempt at the same invocation-owned path.
          trap '' HUP INT TERM
          cleanup_signals_frozen=1
          if [ -e "$plan_dir" ]; then
            if rm -rf "$plan_dir"; then
              cleanup_rc=0
            else
              cleanup_rc=$?
            fi
          fi
        fi
        if [ -e "$plan_dir" ]; then
          echo "autolint: could not remove registry plan temp directory" >&2
          cleanup_rc=125
        else
          cleanup_rc=0
        fi
        if [ "$managed_parallel" -eq 1 ] &&
          [ "$_autolint_signal_status" -ne 0 ]; then
          rc=$_autolint_signal_status
        elif [ "$cleanup_rc" -ne 0 ]; then
          rc=$(_autolint_merge_rc "$rc" "$cleanup_rc")
        fi
        if [ "$managed_parallel" -eq 1 ]; then
          _autolint_restore_signal_traps "$saved_hup" "$saved_int" "$saved_term"
          if [ "$_autolint_signal_status" -ne 0 ]; then
            rc=$_autolint_signal_status
          fi
        fi
        if [ "$direct_fallback" -eq 1 ] &&
          [ "$_autolint_signal_status" -eq 0 ]; then
          # Cleanup failure already makes the final result structural, but it
          # must not turn a requested lint operation into a no-op. Run the
          # foreground batched fallback under restored caller traps, then merge
          # its result with any stronger cleanup status retained above.
          if _autolint_run_direct_read_only_fallback \
            "$jobs" "${lint_files[@]}"; then
            file_rc=0
          else
            file_rc=$?
          fi
          rc=$(_autolint_merge_rc "$rc" "$file_rc")
        fi
      else
        if [ "$managed_parallel" -eq 1 ]; then
          if [ "$_autolint_signal_status" -ne 0 ]; then
            trap '' HUP INT TERM
            rc=$_autolint_signal_status
          fi
          _autolint_restore_signal_traps "$saved_hup" "$saved_int" "$saved_term"
          if [ "$_autolint_signal_status" -ne 0 ]; then
            rc=$_autolint_signal_status
          fi
        fi
        if [ "$rc" -eq 0 ]; then
          # No scratch was allocated. Restore direct caller semantics before
          # the historical per-file fallback for the same reason as the
          # validation/capability path above.
          for file in "${lint_files[@]}"; do
            if _lint_one "$file"; then
              file_rc=0
            else
              file_rc=$?
            fi
            rc=$(_autolint_merge_rc "$rc" "$file_rc")
          done
        fi
      fi
    fi
  fi

  return "$rc"
}

_autolint_note_findings() {
  # Workers are subshells, so the only state they share with the invocation
  # is the filesystem: append to the report itself. `_autolint_finish_report`
  # turns any appended content into `findings=1`.
  [ -n "${_autolint_report:-}" ] || return 0
  printf 'finding\n' 2>/dev/null >>"$_autolint_report"
}

_autolint_finish_report() {
  local rc="$1" findings=0
  [ -n "${_autolint_report:-}" ] || return 0
  # A signal status proves nothing about the files, so leave the truncated
  # report, which readers must not trust, rather than claim a complete run.
  [ "$rc" -le 128 ] || return 0
  [ -s "$_autolint_report" ] && findings=1
  printf 'findings=%s\n' "$findings" 2>/dev/null >"$_autolint_report" || {
    echo "autolint: could not write CHECKRUN_AUTOLINT_REPORT: $_autolint_report" >&2
    return 0
  }
}

# Entry point. CHECKRUN_AUTOLINT_REPORT names a file that receives
# `findings=0` or `findings=1` once the run completes. Exit 2 (a tool or
# structural failure) outranks ordinary findings, so a caller that may
# tolerate tool failures needs to know whether findings were hidden behind
# it; `findings=1` means some lint step or file reported a status other than
# 0 (clean) or 2 (tool failure). The file is truncated first, so an
# interrupted run leaves no `findings=0` behind, and nothing is written when
# the variable is unset. A report that cannot be written only warns; a
# finding that cannot be recorded mid-run fails the run with status 125.
_autolint_main() {
  local rc=0 _autolint_report=""
  if [ -n "${CHECKRUN_AUTOLINT_REPORT:-}" ]; then
    if : 2>/dev/null >"$CHECKRUN_AUTOLINT_REPORT"; then
      _autolint_report=$CHECKRUN_AUTOLINT_REPORT
    else
      echo "autolint: could not write CHECKRUN_AUTOLINT_REPORT: $CHECKRUN_AUTOLINT_REPORT" >&2
    fi
  fi
  _autolint_run "$@"
  rc=$?
  _autolint_finish_report "$rc"
  return "$rc"
}
