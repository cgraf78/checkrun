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
  local file="$1" _filedir ext rc=0
  local _is_cmake=0 _is_dockerfile=0 _is_makefile=0 _is_starlark=0

  _filedir=$(dirname "$file")
  ext="${file##*.}"

  # Spell checking is cross-cutting rather than extension-owned. Run it
  # before language dispatch so docs, comments, configs, and scripts get
  # the same typo policy without duplicating branches below.
  _lint_typos "$file" "$_filedir" || rc=$?

  # Schema validation is policy-driven rather than extension-owned. Run it
  # once near the top so editor, hook, and CLI callers all share the same
  # public-schema checks for dotfile-specific config names.
  _lint_schema "$file" || rc=$?

  # Basename dispatch for files where the name — not extension — indicates
  # the language (Dockerfiles, Starlark build files). Runs before extension
  # dispatch and exits on match so neither path can fire for the same file.
  case "${file##*/}" in
    Dockerfile | Dockerfile.* | Containerfile | Containerfile.*)
      _is_dockerfile=1
      ;;
    BUCK | BUCK.* | BUILD | BUILD.* | TARGETS | TARGETS.* | WORKSPACE | WORKSPACE.* | MODULE.bazel)
      _is_starlark=1
      ;;
    Makefile | makefile | GNUmakefile)
      _is_makefile=1
      ;;
    CMakeLists.txt)
      _is_cmake=1
      ;;
  esac

  # These are config syntaxes with reliable parser/dry-run commands,
  # but they do not map cleanly to a file extension. Keep them scoped to
  # known basenames/paths instead of treating every `.conf` alike.
  # Deliberately exclude SSH config: `ssh -G -F <file>` executes
  # `Match exec` while parsing, which is not safe for automatic hooks.
  case "$file" in
    */cron | */crontab | *.cron)
      _lint_crontab "$file" || rc=$?
      return "$rc"
      ;;
    */tmux.conf)
      _lint_tmux_config "$file" || rc=$?
      return "$rc"
      ;;
    */.gitconfig | */.config/git/config)
      _lint_git_config "$file" || rc=$?
      return "$rc"
      ;;
    */.editorconfig)
      _lint_editorconfig "$file" || rc=$?
      return "$rc"
      ;;
  esac

  # Per-language dispatch. Each arm mirrors autoformat's three-step
  # shape (tool-present guard → per-repo config detection → fallback
  # via `$CHECKRUN_AUTOLINT_DIR`). Exceptions:
  #   - `zsh` has no config mechanism; we just run `zsh -n`.
  #   - `yml/yaml` is scoped to `*/.github/workflows/*` — actionlint
  #     and zizmor are workflow-specific and would be noisy on arbitrary yamls.

  # Basename dispatch: Dockerfiles and Starlark build files are identified
  # by name, not extension. Flags were set earlier; act on them here so
  # the extension case below can fall through normally.
  if [ "${_is_dockerfile:-0}" -eq 1 ]; then
    _lint_dockerfile "$file" "$_filedir" || rc=$?
    return "$rc"
  fi

  if [ "${_is_starlark:-0}" -eq 1 ]; then
    _lint_buildifier "$file" || rc=$?
    return "$rc"
  fi

  if [ "${_is_makefile:-0}" -eq 1 ]; then
    _lint_checkmake "$file" "$_filedir" || rc=$?
    return "$rc"
  fi

  if [ "${_is_cmake:-0}" -eq 1 ]; then
    _lint_cmake "$file" "$_filedir" || rc=$?
    return "$rc"
  fi

  case "$ext" in
    cmake)
      _lint_cmake "$file" "$_filedir" || rc=$?
      ;;
    mk)
      _lint_checkmake "$file" "$_filedir" || rc=$?
      ;;
    sh | bash)
      _lint_sh "$file" "$_filedir" || rc=$?
      ;;
    zsh)
      _lint_zsh "$file" || rc=$?
      ;;
    go)
      _lint_go "$file" "$_filedir" || rc=$?
      ;;
    java)
      _lint_java "$file" || rc=$?
      ;;
    htm | html)
      _lint_superhtml "$file" || rc=$?
      ;;
    bzl | star)
      _lint_buildifier "$file" || rc=$?
      ;;
    py)
      _lint_ruff "$file" "$_filedir" || rc=$?
      ;;
    rb)
      _lint_ruby "$file" "$_filedir" || rc=$?
      ;;
    rs)
      _lint_rust "$file" "$_filedir" || rc=$?
      ;;
    php)
      _lint_php "$file" || rc=$?
      ;;
    css | js | jsx | json | jsonc | ts | tsx)
      _lint_biome "$file" "$_filedir" || rc=$?
      ;;
    automount | device | mount | path | scope | service | slice | socket | swap | target | timer)
      _lint_systemd_unit "$file" || rc=$?
      ;;
    md)
      _lint_rumdl "$file" "$_filedir" || rc=$?
      ;;
    toml)
      _lint_taplo "$file" "$_filedir" || rc=$?
      ;;
    lua)
      _lint_selene "$file" "$_filedir" || rc=$?
      ;;
    yml | yaml)
      # Only lint GitHub Actions workflow YAML. A generic YAML linter on
      # arbitrary yamls is too noisy; actionlint is scoped to workflows.
      _lint_github_workflow "$file" || rc=$?
      ;;
    *)
      # Extensionless files: dispatch via _classify_shell (dotfile name or shebang).
      case "$(_classify_shell "$file")" in
        zsh) _lint_zsh "$file" || rc=$? ;;
        bash) _lint_sh "$file" "$_filedir" "$(_shellcheck_lang_hint "$file")" || rc=$? ;;
      esac
      ;;
  esac

  return "$rc"
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

  if ! command -v yq >/dev/null 2>&1; then
    echo "autolint: yq is required" >&2
    return 1
  fi

  # `--json` relies on jq to transform each tool's native JSON into the
  # unified schema. Bail only after no-op paths are filtered so missing
  # or ignored files keep the same graceful-skip behavior as normal mode.
  if [ "$json" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
    echo "autolint: jq is required for --json" >&2
    return 1
  fi

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
