#!/usr/bin/env bash
# autolint implementation — lint files by extension.
# Requires yq, which should be installed by the host bootstrap path.
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
    "  Shell:     .sh, .bash, .zsh, shell shebangs, .bashrc, .zshrc, .envrc" \
    "  Systemd:   .automount, .device, .mount, .path, .scope, .service, .slice, .socket, .swap, .target, .timer" \
    "  Web/data:  .css, .js, .jsx, .ts, .tsx, .json, .jsonc, .html, .htm" \
    "" \
    "Options:" \
    "  --fix       Apply safe linter fixes where supported." \
    "  --json      Emit one unified JSON diagnostic per output line." \
    "  -h, --help  Show this help and exit."
}

_lint_one() {
  local file="$1" plan row path filetype step_phase adapter config_source config_path
  local rc=0 tool_rc dir

  # The registry planner is the policy boundary for linting: it owns matching,
  # cross-cutting spell/schema ordering, path-scoped workflow tools, and every
  # phase-specific ignore file. Shell code below only translates adapter ids
  # into concrete tool invocations.
  plan=$(_checkrun_registry shell-plan --phase lint -- "$file")
  tool_rc=$?
  [ "$tool_rc" -ne 0 ] && return "$tool_rc"
  [ -n "$plan" ] || return 0

  # yq/jq remain execution dependencies, not planning dependencies. Check them
  # only after the registry says at least one lint step will run, so missing or
  # ignored files keep the same graceful skip behavior as before.
  if ! command -v yq >/dev/null 2>&1; then
    echo "autolint: yq is required" >&2
    return 1
  fi
  if [ "$json" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
    echo "autolint: jq is required for --json" >&2
    return 1
  fi

  while IFS= read -r row || [ -n "$row" ]; do
    IFS=$'\t' read -r path filetype step_phase adapter config_source config_path <<EOF
$row
EOF
    dir=$(dirname "$path")
    _lint_dispatch "$adapter" "$path" "$filetype" "$step_phase" "$config_source" "$config_path" "$dir" || rc=$?
  done <<<"$plan"

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

_autolint_run_file_batch() {
  local rc=0 file_rc batch_file stdout_file stderr_file pid index
  local -a batch_files=("$@")
  local -a batch_pids=() batch_stdout_files=() batch_stderr_files=()

  for batch_file in "${batch_files[@]}"; do
    stdout_file=$(mktemp "${TMPDIR:-/tmp}/autolint-stdout.XXXXXX")
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/autolint-stderr.XXXXXX")
    (
      _lint_one "$batch_file"
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
    [ "$file_rc" -ne 0 ] && rc=$file_rc
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

  # Fallback-config dir. Defaults to the same dir autoformat uses because
  # several backends share one policy file for formatting and linting. Can be
  # overridden independently via CHECKRUN_AUTOLINT_DIR.
  CHECKRUN_AUTOLINT_DIR="${CHECKRUN_AUTOLINT_DIR:-$HOME/.config/autoformat}"

  # Resolve relative CHECKRUN_AUTOLINT_DIR values before any linter-specific cwd
  # changes. Config paths passed on the CLI should name the same file
  # regardless of where the backend command eventually runs.
  if [ -d "$CHECKRUN_AUTOLINT_DIR" ]; then
    CHECKRUN_AUTOLINT_DIR=$(_abs_dir "$CHECKRUN_AUTOLINT_DIR")
  fi

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
      _lint_one "$file" || rc=$?
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
        _lint_one "$file" || rc=$?
      done
    else
      for ((start = 0; start < ${#lint_files[@]}; start += jobs)); do
        _autolint_run_file_batch "${lint_files[@]:start:jobs}" || rc=$?
      done
    fi
  fi

  return "$rc"
}
