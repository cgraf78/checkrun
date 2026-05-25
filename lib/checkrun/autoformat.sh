#!/usr/bin/env bash
# autoformat implementation — auto-format files by extension.
# Requires yq, which should be installed by the host bootstrap path.
# No-ops gracefully if a formatter is not installed.
# Respects per-repo config files; uses ~/.config/autoformat/ when absent.
#
# Usage: autoformat [-h|--help] <file> [file...]

set -u

# shellcheck source=common.sh
CHECKRUN_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$CHECKRUN_LIB_DIR" == "${BASH_SOURCE[0]}" ]] && CHECKRUN_LIB_DIR=.
. "$CHECKRUN_LIB_DIR/common.sh"

_autoformat_usage() {
  printf '%s\n' \
    "Usage: autoformat [-h|--help] <file> [file...]" \
    "" \
    "Auto-format files by extension. Unsupported files, missing files, ignored" \
    "files, and files whose formatter is not installed are skipped." \
    "" \
    "Supported file types:" \
    "  Build:     .bzl, BUCK, BUILD, CMakeLists.txt, .cmake" \
    "  C/C++:     .c, .cc, .cpp, .cxx, .h, .hpp, .hxx" \
    "  Config:    .toml, .yaml, .yml" \
    "  Container: Dockerfile, Containerfile" \
    "  Docs/text: .md" \
    "  Go:        .go" \
    "  Java:      .java" \
    "  Lua:       .lua" \
    "  PHP:       .php" \
    "  Python:    .py" \
    "  Ruby:      .rb" \
    "  Rust:      .rs" \
    "  Shell:     .sh, .bash, .zsh, shell shebangs, .bashrc, .zshrc, .profile, .envrc" \
    "  Web/data:  .css, .js, .jsx, .ts, .tsx, .json, .jsonc, .html, .htm" \
    "" \
    "Options:" \
    "  -h, --help  Show this help and exit."
}

# Run a formatter, buffering stderr so successful runs stay silent.
# Several formatters chat on stderr even on success (prettier emits
# "path 12ms", clang-format and shfmt occasionally warn on benign
# input); that noise drowns out the edit-hook output on every save.
# If the formatter fails we surface the buffered stderr so real
# problems still land in the user's console.
_run_fmt() {
  local err rc
  # If mktemp fails (full disk, read-only $TMPDIR) we still want the
  # formatter to run — just skip the stderr buffering and let the
  # caller see whatever chatter the tool produces. Worse UX but still
  # correct output.
  if ! err=$(mktemp 2>/dev/null); then
    "$@"
    return $?
  fi
  "$@" 2>"$err"
  rc=$?
  if [ "$rc" -ne 0 ] && [ -s "$err" ]; then
    cat "$err" >&2
  fi
  rm -f "$err"
  return "$rc"
}

# Dispatch sh/bash/zsh through a single shfmt invocation. Exists
# purely to dedupe the three extension branches plus the extensionless
# shebang path; `lang` is the `-ln` value ("" for default bash parsing,
# "zsh" for zsh scripts).
_format_sh() {
  local file="$1" dir="$2" lang="${3:-}" config_source="${4:-}" config_path="${5:-}"
  local args=() v_indent="" v_sci=""

  [ -n "$lang" ] && args+=("-ln=$lang")

  # shfmt reads EditorConfig on its own. Only translate the fallback
  # TOML into CLI flags when the repo has no .editorconfig, otherwise
  # the explicit flags would override the repo's local style.
  if [ "$config_source" = "fallback" ] && [ -f "$config_path" ]; then
    {
      read -r v_indent
      read -r v_sci
    } < <(
      _toml_read_keys "$config_path" indent switch_case_indent
    )
    [ -n "$v_indent" ] && args+=(-i "$v_indent")
    [ "$v_sci" = "true" ] && args+=(-ci)
  fi

  _run_fmt shfmt ${args[@]+"${args[@]}"} -w "$file"
}

_format_cmake() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v cmake-format &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config-files "$config_path")
  _run_fmt cmake-format -i ${args[@]+"${args[@]}"} "$file"
}

_format_ruby() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v rubocop &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config "$config_path")
  # Limit autoformat to RuboCop's Layout department. Full RuboCop
  # autocorrect can rewrite code semantics; layout-only keeps save-time
  # formatting predictable while autolint handles broader diagnostics.
  _run_fmt rubocop --autocorrect --only Layout --format quiet \
    ${args[@]+"${args[@]}"} "$file"
}

_format_php() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v php-cs-fixer &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config "$config_path")
  _run_fmt php-cs-fixer fix --quiet --using-cache=no ${args[@]+"${args[@]}"} "$file"
}

_format_java() {
  local file="$1"
  command -v google-java-format &>/dev/null || return 0
  _run_fmt google-java-format -i "$file"
}

_format_ruff() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v ruff &>/dev/null || return 0

  # The registry already decided whether project policy or fallback policy
  # applies. Only force Ruff's config for the fallback case: project-local
  # pyproject/ruff.toml discovery is Ruff's native behavior and keeps relative
  # config includes interpreted the way Ruff expects.
  [ "$config_source" = "fallback" ] && [ -n "$config_path" ] && args=(--config "$config_path")
  _run_fmt ruff format --quiet ${args[@]+"${args[@]}"} "$file"
  # Also sort imports (`I` rule) as a format-adjacent fix. The full lint rule
  # set runs via autolint --fix; scoping here to imports-only keeps
  # autoformat-on-save deterministic and avoids broad lint rewrites.
  _run_fmt ruff check --quiet --fix --select=I ${args[@]+"${args[@]}"} "$file"
}

_format_goimports() {
  local file="$1"
  command -v goimports &>/dev/null || return 0
  _run_fmt goimports -w "$file"
}

_format_gofumpt() {
  local file="$1"
  command -v gofumpt &>/dev/null || return 0
  _run_fmt gofumpt -w "$file"
}

_format_sh_zsh() {
  _format_sh "$1" "$2" "zsh" "${3:-}" "${4:-}"
}

_format_clang() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v clang-format &>/dev/null || return 0

  # clang-format walks for project `.clang-format` files by itself, but it does
  # not know about the personal fallback file. The registry tells us when the
  # fallback is the selected policy, and only that case needs an explicit style.
  if [ "$config_source" = "fallback" ] && [ -n "$config_path" ]; then
    args=(-style="file:$config_path")
  fi
  _run_fmt clang-format -i ${args[@]+"${args[@]}"} "$file"
}

_format_stylua() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v stylua &>/dev/null || return 0

  # stylua treats stylua.toml and .editorconfig as project style sources. Pass
  # only the fallback explicitly so project policy remains native and local.
  if [ "$config_source" = "fallback" ] && [ -n "$config_path" ]; then
    args=(--config-path "$config_path")
  fi
  _run_fmt stylua ${args[@]+"${args[@]}"} "$file"
}

_format_rustfmt() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}"
  local args=() cargo_edition
  command -v rustfmt &>/dev/null || return 0

  # Cargo owns parser edition, while rustfmt.toml owns style. Keeping edition
  # inference in the adapter avoids turning the registry into a project model.
  cargo_edition=$(_find_cargo_edition "$dir" 2>/dev/null || true)
  [ -n "$cargo_edition" ] && args+=(--edition "$cargo_edition")
  if [ "$config_source" = "fallback" ] && [ -n "$config_path" ]; then
    args+=(--config-path "$config_path")
  fi
  _run_fmt rustfmt ${args[@]+"${args[@]}"} "$file"
}

_format_taplo() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v taplo &>/dev/null || return 0

  # taplo's config discovery starts from process cwd, so both project and
  # fallback selections from the registry are passed explicitly.
  [ -n "$config_path" ] && args=(--config "$config_path")
  _run_fmt taplo fmt ${args[@]+"${args[@]}"} "$file"
}

_format_biome() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v biome &>/dev/null || return 0

  # Biome accepts a config root directory, not the config file. The registry's
  # self-config guard returns `native` for the config file itself so we avoid
  # handing Biome the same root twice and triggering nested-root errors.
  if [ "$config_source" != "native" ] && [ -n "$config_path" ]; then
    args=(--config-path "$(dirname "$config_path")")
  fi
  # `biome check --write --linter-enabled=false` runs formatter + assist
  # (organize imports etc.) but skips lint fixes. Autolint owns lint fixes so
  # save-time formatting never applies broader behavior-changing rewrites.
  _run_fmt biome check --write --linter-enabled=false \
    ${args[@]+"${args[@]}"} "$file"
}

_format_superhtml() {
  local file="$1"
  command -v superhtml &>/dev/null || return 0
  _run_fmt superhtml fmt "$file"
}

_format_buildifier() {
  local file="$1"
  command -v buildifier &>/dev/null || return 0
  _run_fmt buildifier "$file"
}

_format_dockerfmt() {
  local file="$1"
  command -v dockerfmt &>/dev/null || return 0
  _run_fmt dockerfmt -w "$file"
}

_format_yamlfmt() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v yamlfmt &>/dev/null || return 0

  # yamlfmt does not walk upward from the target file. The registry walk gives
  # us a cwd-independent config path, so pass project and fallback policies.
  [ -n "$config_path" ] && args=(-conf "$config_path")
  _run_fmt yamlfmt ${args[@]+"${args[@]}"} "$file"
}

_format_rumdl() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v rumdl &>/dev/null || return 0

  # rumdl --fix doubles as a formatter: it auto-fixes markdown rule violations
  # without becoming a prose reflower. Keep project config native but point at
  # the fallback when the registry selected personal policy.
  if [ "$config_source" = "fallback" ] && [ -n "$config_path" ]; then
    args=(--config "$config_path")
  fi
  _run_fmt rumdl check --fix ${args[@]+"${args[@]}"} "$file"
}

_format_dispatch() {
  local adapter="$1" file="$2" filetype="$3" config_source="$4" config_path="$5"
  local dir
  dir=$(dirname "$file")

  # Adapter ids are the stable boundary between the registry and shell. This
  # case statement intentionally dispatches by adapter id only; filetype,
  # extension, basename, path-scope, and ignore decisions have already happened
  # inside the registry interpreter.
  case "$adapter" in
    biome-format) _format_biome "$file" "$dir" "$config_source" "$config_path" ;;
    buildifier-format) _format_buildifier "$file" "$dir" "$config_source" "$config_path" ;;
    clang-format) _format_clang "$file" "$dir" "$config_source" "$config_path" ;;
    cmake-format) _format_cmake "$file" "$dir" "$config_source" "$config_path" ;;
    dockerfmt) _format_dockerfmt "$file" "$dir" "$config_source" "$config_path" ;;
    gofumpt) _format_gofumpt "$file" "$dir" "$config_source" "$config_path" ;;
    goimports) _format_goimports "$file" "$dir" "$config_source" "$config_path" ;;
    google-java-format) _format_java "$file" "$dir" "$config_source" "$config_path" ;;
    php-cs-fixer) _format_php "$file" "$dir" "$config_source" "$config_path" ;;
    rubocop-format) _format_ruby "$file" "$dir" "$config_source" "$config_path" ;;
    ruff-format) _format_ruff "$file" "$dir" "$config_source" "$config_path" ;;
    rumdl-format) _format_rumdl "$file" "$dir" "$config_source" "$config_path" ;;
    rustfmt) _format_rustfmt "$file" "$dir" "$config_source" "$config_path" ;;
    shfmt) _format_sh "$file" "$dir" "" "$config_source" "$config_path" ;;
    shfmt-zsh) _format_sh_zsh "$file" "$dir" "$config_source" "$config_path" ;;
    stylua) _format_stylua "$file" "$dir" "$config_source" "$config_path" ;;
    superhtml-format) _format_superhtml "$file" "$dir" "$config_source" "$config_path" ;;
    taplo-format) _format_taplo "$file" "$dir" "$config_source" "$config_path" ;;
    yamlfmt) _format_yamlfmt "$file" "$dir" "$config_source" "$config_path" ;;
  esac
}

_format_one() {
  local file="$1" plan row path filetype _phase adapter config_source config_path rc

  [ -z "$file" ] && return 0

  # Planning is the one place where filename, extension, shebang, path scope,
  # ignore files, and config-policy discovery are allowed to interact. Keeping
  # that work out of shell dispatch prevents the old metadata-vs-execution
  # drift from returning in a second table.
  plan=$("$CHECKRUN_LIB_DIR/registry.py" shell-plan --phase format -- "$file")
  rc=$?
  [ "$rc" -ne 0 ] && return "$rc"

  [ -n "$plan" ] || return 0
  while IFS= read -r row || [ -n "$row" ]; do
    IFS=$'\t' read -r path filetype _phase adapter config_source config_path <<EOF
$row
EOF
    # Formatter failures are advisory by design: `_run_fmt` surfaces useful
    # stderr, and the save hook continues with exit 0. Registry failures above
    # are different and propagate because they mean Checkrun itself is invalid.
    _format_dispatch "$adapter" "$path" "$filetype" "$config_source" "$config_path" || true
  done <<<"$plan"

  return 0
}

_autoformat_main() {
  local arg file

  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        _autoformat_usage
        return 0
        ;;
    esac
  done

  CHECKRUN_AUTOFORMAT_DIR="${CHECKRUN_AUTOFORMAT_DIR:-$HOME/.config/autoformat}"

  # Resolve relative CHECKRUN_AUTOFORMAT_DIR values at startup. Formatter branches
  # pass fallback configs directly to tools, and some tools resolve those
  # paths after changing cwd or walking from cwd instead of from the file.
  if [ -d "$CHECKRUN_AUTOFORMAT_DIR" ]; then
    CHECKRUN_AUTOFORMAT_DIR=$(_abs_dir "$CHECKRUN_AUTOFORMAT_DIR")
  fi

  if ! command -v yq >/dev/null 2>&1; then
    echo "autoformat: yq is required" >&2
    return 1
  fi

  for file in "$@"; do
    _format_one "$file"
  done

  return 0
}
