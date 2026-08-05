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
    "" \
    "Lint files by extension. Unsupported files, missing files, ignored files," \
    "and files whose linter is not installed are skipped." \
    "" \
    "Supported file types:" \
    "  Build:     .bzl, BUCK, BUILD, CMakeLists.txt, .cmake, Makefile, GNUmakefile, .mk, .mak" \
    "  CI:        .github/workflows/*.yml, .github/workflows/*.yaml" \
    "  Config:    .editorconfig, .toml, git config, tmux.conf, crontab" \
    "  Container: Dockerfile, Containerfile" \
    "  Docs/text: .md and plain text via typos when available" \
    "  Go:        .go" \
    "  Java:      .java" \
    "  Lua:       .lua" \
    "  Nix:       .nix" \
    "  PHP:       .php" \
    "  Protobuf:  .proto" \
    "  Python:    .py" \
    "  Ruby:      .rb" \
    "  Rust:      .rs" \
    "  Shell:     .sh, .bash, .zsh, extensionless files with a shell shebang, .bashrc, .zshrc, .envrc" \
    "  Systemd:   .automount, .device, .mount, .path, .scope, .service, .slice, .socket, .swap, .target, .timer" \
    "  Web/data:  .css, .scss, .less, .js, .jsx, .ts, .tsx, .json, .jsonc, .html, .htm" \
    "" \
    "Options:" \
    "  --fix       Apply safe linter fixes where supported." \
    "  --json      Emit one unified JSON diagnostic per output line." \
    "  -h, --help  Show this help and exit." \
    "" \
    "Environment:" \
    "  CHECKRUN_AUTOLINT_JOBS  Override parallel worker count (default: min(cores, 8))." \
    "  CHECKRUN_CONFIG_DIR       Fallback config directory (default: XDG config root)."
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
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  done <"$plan_file"

  return "$rc"
}

_lint_one() {
  # Plan one file inline (one Python invocation per call) and dispatch. Used by
  # --fix mode and read-only fallbacks without planner scratch. Normal read-only
  # paths use _autolint_pre_plan plus _lint_one_with_plan so the Python planner
  # runs once total, including when jobs=1.
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
  local out_dir="$1"
  shift
  _checkrun_registry shell-plan --output-dir "$out_dir" --phase lint -- "$@"
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

_autolint_try_clean_batch() {
  local plan_dir="$1"
  local filetype step_phase adapter config_source config_path index batch_stderr
  local -a files batch_filetypes batch_phases batch_adapters batch_sources batch_paths
  shift
  files=("$@")

  [ "${#files[@]}" -gt 1 ] || return 1
  [ -s "$plan_dir/batch.plan" ] || return 1
  command -v yq >/dev/null 2>&1 || return 1

  # Validate the complete manifest before running any backend. This keeps a
  # future non-batchable adapter from causing partial speculative work before
  # the established per-file path takes over.
  while IFS= read -r -d '' filetype &&
    IFS= read -r -d '' step_phase &&
    IFS= read -r -d '' adapter &&
    IFS= read -r -d '' config_source &&
    IFS= read -r -d '' config_path; do
    # ShellCheck is intentionally absent: giving it multiple inputs changes
    # source-following diagnostics, so process batching is not equivalent to
    # the established independent-file checks.
    case "$adapter" in
      ruff-lint | selene | typos) ;;
      *) return 1 ;;
    esac
    batch_filetypes+=("$filetype")
    batch_phases+=("$step_phase")
    batch_adapters+=("$adapter")
    batch_sources+=("$config_source")
    batch_paths+=("$config_path")
  done <"$plan_dir/batch.plan"

  [ "${#batch_adapters[@]}" -gt 0 ] || return 1
  batch_stderr="$plan_dir/batch.stderr"
  : >"$batch_stderr" || return 1
  for index in "${!batch_adapters[@]}"; do
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || {
      rm -f "$batch_stderr"
      return "$_autolint_cancel_status"
    }
    # Routine clean stdout is intentionally quiet. Buffer exit-0 warnings until
    # every adapter succeeds; a failed probe discards both streams and reruns
    # the authoritative per-file path so diagnostic order and attribution stay
    # unchanged.
    _autolint_run_clean_batch_step \
      "${batch_adapters[$index]}" \
      "${batch_filetypes[$index]}" \
      "${batch_phases[$index]}" \
      "${batch_sources[$index]}" \
      "${batch_paths[$index]}" \
      "${files[@]}" >/dev/null 2>>"$batch_stderr" || {
      rm -f "$batch_stderr"
      return 1
    }
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || {
      rm -f "$batch_stderr"
      return "$_autolint_cancel_status"
    }
  done
  [ -s "$batch_stderr" ] && cat "$batch_stderr" >&2
  rm -f "$batch_stderr" || true
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
# including macOS's system bash 3.2 — must use the barrier path above. CI
# verifies that every supported modern Bash retains a child's status for the
# later exact-PID wait used by the ordered-output pass.
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

  # Spawn-and-reap loop. `wait -n` blocks until any one child finishes; its
  # exit status reflects that child but we don't need to map it back to a pid
  # here — we'll wait on each specific pid in the in-order pass below to pick
  # up the correct per-file rc. A wait on an already-finished child returns
  # immediately with its stored exit status, so this is cheap.
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
        _lint_one_with_plan "$plan_dir/$next.plan"
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
      # `wait -n` returns 127 only when there are no children to wait for.
      # Our in_flight counter guards against that case, so any exit status
      # here belongs to a real worker.
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
    if wait "${pids[$i]}"; then
      file_rc=0
    else
      file_rc=$?
    fi
    if [ "${_autolint_cancel_status:-0}" -ne 0 ]; then
      _autolint_reap_pids "${pids[@]+"${pids[@]}"}"
      return "$_autolint_cancel_status"
    fi
    [ -s "${stdouts[$i]}" ] && cat "${stdouts[$i]}"
    [ -s "${stderrs[$i]}" ] && cat "${stderrs[$i]}" >&2
    rc=$(_autolint_merge_rc "$rc" "$file_rc")
  done

  return "$rc"
}

_autolint_record_signal() {
  local status="$1"
  [ "${_autolint_signal_status:-0}" -ne 0 ] || _autolint_signal_status=$status
  [ "${_autolint_cancel_status:-0}" -ne 0 ] || _autolint_cancel_status=$status
}

_autolint_restore_signal_traps() {
  local saved_hup="$1" saved_int="$2" saved_term="$3"
  eval "${saved_hup:-trap - HUP}"
  eval "${saved_int:-trap - INT}"
  eval "${saved_term:-trap - TERM}"
}

_autolint_process_group() {
  local pid="$1" snapshot group
  case "$pid" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  snapshot=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null) || return 1
  group=$(awk '
    NF == 1 && $1 ~ /^[0-9]+$/ { group = $1; matches++ }
    NF != 1 { invalid = 1 }
    END {
      if (invalid || matches != 1) exit 1
      print group
    }
  ' <<<"$snapshot") || return 1
  REPLY=$group
}

_autolint_validate_private_group() {
  local leader="$1" caller_pid="$2" jobs_file="$3"
  local job_leader leader_group caller_group
  case "$leader" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$leader" 2>/dev/null || return 1
  # `jobs -p` confirms that the exact unreaped `$!` is still our Bash job, but
  # some Bash/platform combinations can report `$!` even when the process is
  # still in the caller's group. Verify both real PGIDs before group signalling.
  jobs -p >"$jobs_file" || return 1
  while IFS= read -r job_leader; do
    if [ "$job_leader" = "$leader" ]; then
      _autolint_process_group "$leader" || return 1
      leader_group=$REPLY
      [ "$leader_group" = "$leader" ] || return 1
      _autolint_process_group "$caller_pid" || return 1
      caller_group=$REPLY
      [ "$leader_group" != "$caller_group" ] || return 1
      REPLY=$leader_group
      return 0
    fi
  done <"$jobs_file"
  return 1
}

_autolint_group_has_live_processes() {
  local group="$1" snapshot rc
  snapshot=$(LC_ALL=C ps -eo pgid=,stat= 2>/dev/null) || return 2
  awk -v group="$group" '
    $1 == group && $2 !~ /^[ZX]/ { found = 1 }
    END { exit !found }
  ' <<<"$snapshot"
  rc=$?
  case "$rc" in
    0 | 1) return "$rc" ;;
    *) return 2 ;;
  esac
}

_autolint_stop_unvalidated_leader() {
  local leader="$1" attempt
  case "$leader" in
    '' | 0 | *[!0-9]*) return 0 ;;
  esac
  kill -TERM "$leader" 2>/dev/null || true
  for ((attempt = 0; attempt < 20; attempt++)); do
    kill -0 "$leader" 2>/dev/null || break
    sleep 0.01
  done
  if kill -0 "$leader" 2>/dev/null; then
    kill -KILL "$leader" 2>/dev/null || true
  fi
  wait "$leader" 2>/dev/null || true
}

_autolint_cancel_private_group() {
  local leader="$1" group="$2" done_file="$3" attempt group_state live=1

  trap '' HUP INT TERM
  if [ ! -e "$done_file" ]; then
    kill -TERM "-$group" 2>/dev/null || true
    # The supervisor writes its completion marker only after its exact workers
    # quiesce. Poll that cheap condition first; inspect the complete group once
    # afterward so an ignored TERM cannot hide behind a finished supervisor.
    for ((attempt = 0; attempt < 20; attempt++)); do
      [ -e "$done_file" ] && break
      sleep 0.01
    done
  fi
  if _autolint_group_has_live_processes "$group"; then
    live=1
  else
    group_state=$?
    # A failed process-table snapshot is unknown, not proof of completion.
    # The validated group is still anchored by the exact unwaited leader, so
    # conservative escalation is safer than blocking forever on a survivor.
    [ "$group_state" -eq 1 ] && live=0 || live=1
  fi
  if [ "$live" -ne 0 ]; then
    kill -KILL "-$group" 2>/dev/null || true
  fi
  wait "$leader" 2>/dev/null || true
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
  local plan_rc=0 nonempty=0 run_rc=0
  local -a files=("$@")

  [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
  _autolint_pre_plan "$plan_dir" "${files[@]}" || plan_rc=$?
  [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
  [ "$plan_rc" -eq 0 ] || return "$plan_rc"

  if [ "$json" -eq 0 ]; then
    if _autolint_try_clean_batch "$plan_dir" "${files[@]}"; then
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

_autolint_parallel_supervisor() {
  local gate="$1" parent_pid="$2" jobs="$3" plan_dir="$4"
  shift 4
  local rc=0 _autolint_signal_status=0 _autolint_cancel_status=0
  local -a files=("$@")

  trap '_autolint_record_signal 129' HUP
  trap '_autolint_record_signal 130' INT
  trap '_autolint_record_signal 143' TERM
  while [ ! -d "$gate" ]; do
    [ "${_autolint_cancel_status:-0}" -eq 0 ] || return "$_autolint_cancel_status"
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
  local control_dir="$plan_dir/.supervisor" gate done_file jobs_file
  local parent_pid=${BASHPID:-$$} leader="" group="" rc=0 tool
  local had_monitor=0

  _autolint_parallel_validated=0
  [ "${_autolint_signal_status:-0}" -eq 0 ] || return "$_autolint_signal_status"
  for tool in awk mkdir ps sleep; do
    command -v "$tool" >/dev/null 2>&1 || return 0
  done
  mkdir "$control_dir" 2>/dev/null || return 0
  gate="$control_dir/gate"
  done_file="$control_dir/done"
  jobs_file="$control_dir/jobs"

  [[ "$-" == *m* ]] && had_monitor=1
  if ! set -m 2>/dev/null; then
    return 0
  fi
  (
    set +m
    trap - EXIT
    trap ': >"$done_file" 2>/dev/null || true' EXIT
    _autolint_parallel_supervisor \
      "$gate" "$parent_pid" "$jobs" "$plan_dir" "$@"
  ) </dev/null &
  leader=$!
  # The gated leader is intended to own a private group; validation below is
  # authoritative. Disable notifications while it waits even when the sourced
  # caller started with monitor mode on. Restoring `m` after the exact wait
  # avoids a late `[1]+ Done` diagnostic.
  set +m

  if [ "${_autolint_signal_status:-0}" -ne 0 ]; then
    _autolint_stop_unvalidated_leader "$leader"
    _autolint_restore_monitor "$had_monitor"
    return "$_autolint_signal_status"
  fi
  if ! _autolint_validate_private_group "$leader" "$parent_pid" "$jobs_file"; then
    _autolint_stop_unvalidated_leader "$leader"
    _autolint_restore_monitor "$had_monitor"
    return 0
  fi
  group=$REPLY
  if [ "${_autolint_signal_status:-0}" -ne 0 ]; then
    _autolint_cancel_private_group "$leader" "$group" "$done_file"
    _autolint_restore_monitor "$had_monitor"
    return "$_autolint_signal_status"
  fi
  if ! kill -0 "$leader" 2>/dev/null; then
    _autolint_stop_unvalidated_leader "$leader"
    _autolint_restore_monitor "$had_monitor"
    return 0
  fi
  # Directory creation is the nonblocking gate release. Unlike opening a FIFO
  # writer, it cannot hang if the validated child exits at this boundary.
  if ! mkdir "$gate" 2>/dev/null; then
    _autolint_cancel_private_group "$leader" "$group" "$done_file"
    _autolint_restore_monitor "$had_monitor"
    # Group cleanup shields signals internally. This is a normal capability
    # fallback, not a latched cancellation, so re-arm the parent's handlers
    # before handing control back to exact scratch cleanup.
    trap '_autolint_record_signal 129' HUP
    trap '_autolint_record_signal 130' INT
    trap '_autolint_record_signal 143' TERM
    return 0
  fi
  _autolint_parallel_validated=1

  if [ "${_autolint_signal_status:-0}" -ne 0 ]; then
    _autolint_cancel_private_group "$leader" "$group" "$done_file"
    _autolint_restore_monitor "$had_monitor"
    return "$_autolint_signal_status"
  fi

  if wait "$leader"; then
    rc=0
  else
    rc=$?
  fi
  if [ "${_autolint_signal_status:-0}" -ne 0 ]; then
    # A trap interrupts Bash's wait without reaping the direct child.
    _autolint_cancel_private_group "$leader" "$group" "$done_file"
    _autolint_restore_monitor "$had_monitor"
    return "$_autolint_signal_status"
  fi
  _autolint_restore_monitor "$had_monitor"
  return "$rc"
}

_autolint_main() {
  local fix=0 json=0 rc=0 jobs file lint_file arg
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

  for file in "${file_args[@]}"; do
    if lint_file=$(_lintable_path "$file"); then
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
    if ! command -v mktemp >/dev/null 2>&1 ||
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
        fi
        if [ "$direct_fallback" -eq 1 ] && [ "$rc" -eq 0 ]; then
          for file in "${lint_files[@]}"; do
            if _lint_one "$file"; then
              file_rc=0
            else
              file_rc=$?
            fi
            rc=$(_autolint_merge_rc "$rc" "$file_rc")
          done
        fi
      else
        if [ "$managed_parallel" -eq 1 ]; then
          if [ "$_autolint_signal_status" -ne 0 ]; then
            trap '' HUP INT TERM
            rc=$_autolint_signal_status
          fi
          _autolint_restore_signal_traps "$saved_hup" "$saved_int" "$saved_term"
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
