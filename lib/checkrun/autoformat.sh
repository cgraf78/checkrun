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
  local file="$1" dir="$2" lang="${3:-}"
  local args=() v_indent="" v_sci=""

  [ -n "$lang" ] && args+=("-ln=$lang")

  # shfmt reads EditorConfig on its own. Only translate the fallback
  # TOML into CLI flags when the repo has no .editorconfig, otherwise
  # the explicit flags would override the repo's local style.
  if ! _has_config "$dir" ".editorconfig" &&
    [ -f "$AUTOFORMAT_DIR/shfmt.toml" ]; then
    {
      read -r v_indent
      read -r v_sci
    } < <(
      _toml_read_keys "$AUTOFORMAT_DIR/shfmt.toml" indent switch_case_indent
    )
    [ -n "$v_indent" ] && args+=(-i "$v_indent")
    [ "$v_sci" = "true" ] && args+=(-ci)
  fi

  _run_fmt shfmt "${args[@]}" -w "$file"
}

_format_cmake() {
  local file="$1" dir="$2" cfg args=()
  command -v cmake-format &>/dev/null || return 0

  cfg=$(_find_cmake_config "$dir" "$AUTOFORMAT_DIR" 2>/dev/null || true)
  [ -n "$cfg" ] && args=(--config-files "$cfg")
  _run_fmt cmake-format -i "${args[@]}" "$file"
}

_format_ruby() {
  local file="$1" dir="$2" cfg args=()
  command -v rubocop &>/dev/null || return 0

  cfg=$(_find_rubocop_config "$dir" "$AUTOFORMAT_DIR" 2>/dev/null || true)
  [ -n "$cfg" ] && args=(--config "$cfg")
  # Limit autoformat to RuboCop's Layout department. Full RuboCop
  # autocorrect can rewrite code semantics; layout-only keeps save-time
  # formatting predictable while autolint handles broader diagnostics.
  _run_fmt rubocop --autocorrect --only Layout --format quiet \
    "${args[@]}" "$file"
}

_format_php() {
  local file="$1" dir="$2" cfg args=()
  command -v php-cs-fixer &>/dev/null || return 0

  cfg=$(_find_php_cs_fixer_config "$dir" "$AUTOFORMAT_DIR" 2>/dev/null || true)
  [ -n "$cfg" ] && args=(--config "$cfg")
  _run_fmt php-cs-fixer fix --quiet --using-cache=no "${args[@]}" "$file"
}

_format_java() {
  local file="$1"
  command -v google-java-format &>/dev/null || return 0
  _run_fmt google-java-format -i "$file"
}

_format_one() {
  local file="$1" _filedir ext
  local args=() repo_cfg yamlfmt_cfg cargo_edition
  local has_ruff_config=0

  [ -z "$file" ] && return 0
  [ -f "$file" ] || return 0
  # Normalizing before ignore/config checks keeps hook calls, editor
  # calls, and manual relative invocations on the same policy path.
  file=$(_abs_path "$file") || return 0
  _ignored "$file" "$AUTOFORMAT_DIR/ignore" && return 0

  _filedir=$(dirname "$file")
  ext="${file##*.}"

  # Basename dispatch for files where the name — not extension — indicates
  # the language (Dockerfiles, Starlark build files). Runs before extension
  # dispatch and exits on match so neither path can fire for the same file.
  case "${file##*/}" in
    Dockerfile | Dockerfile.* | Containerfile | Containerfile.*)
      if command -v dockerfmt &>/dev/null; then
        _run_fmt dockerfmt -w "$file"
      fi
      return 0
      ;;
    BUCK | BUCK.* | BUILD | BUILD.* | TARGETS | TARGETS.* | WORKSPACE | WORKSPACE.* | MODULE.bazel)
      if command -v buildifier &>/dev/null; then
        _run_fmt buildifier "$file"
      fi
      return 0
      ;;
    CMakeLists.txt)
      _format_cmake "$file" "$_filedir"
      return 0
      ;;
  esac

  # Design contract shared by every arm below: if the formatter isn't
  # installed, return 0 silently. autoformat fires on every edit-hook
  # save; it must never block the hook because a tool happens to be
  # absent on this host. The `command -v <tool> &>/dev/null` guard at
  # the top of each branch encodes this.
  #
  # Per-language dispatch shape is the same three steps:
  #   1. `command -v <tool>` presence guard (see above).
  #   2. Per-repo config detection via `_has_config` / `_find_config`
  #      (and sometimes a `yq` walk for pyproject-style configs).
  #   3. Fallback to `$AUTOFORMAT_DIR/<tool-config>` via a `--config`-
  #      like CLI flag when no per-repo config was found.
  # Each tool has a slightly different flag name and config-file set;
  # inline comments explain the quirks (e.g. taplo walks from cwd, not
  # the file path).
  case "$ext" in
    py)
      if command -v ruff &>/dev/null; then
        args=()
        has_ruff_config=0
        if _has_config "$_filedir" "ruff.toml" ||
          _has_config "$_filedir" ".ruff.toml" ||
          _walk_config_with_key "$_filedir" pyproject.toml toml \
            '.tool.ruff // .tool.ruff.format'; then
          has_ruff_config=1
        fi
        if [ "$has_ruff_config" -eq 0 ] &&
          [ -f "$AUTOFORMAT_DIR/ruff.toml" ]; then
          args=(--config "$AUTOFORMAT_DIR/ruff.toml")
        fi
        _run_fmt ruff format --quiet "${args[@]}" "$file"
        # Also sort imports (`I` rule) as a format-adjacent fix. The
        # full lint rule set runs via autolint --fix; scoping here to
        # imports-only keeps autoformat's behavior deterministic and
        # unsurprising on save.
        _run_fmt ruff check --quiet --fix --select=I "${args[@]}" "$file"
      fi
      ;;
    go)
      if command -v goimports &>/dev/null; then
        _run_fmt goimports -w "$file"
      fi
      if command -v gofumpt &>/dev/null; then
        _run_fmt gofumpt -w "$file"
      fi
      ;;
    java)
      _format_java "$file"
      ;;
    sh | bash)
      if command -v shfmt &>/dev/null; then
        _format_sh "$file" "$_filedir"
      fi
      ;;
    zsh)
      if command -v shfmt &>/dev/null; then
        _format_sh "$file" "$_filedir" "zsh"
      fi
      ;;
    c | cpp | cc | cxx | h | hpp | hxx)
      if command -v clang-format &>/dev/null; then
        args=()
        # clang-format doesn't walk for a fallback style file the way it
        # walks for a per-repo `.clang-format`. Point it at our fallback
        # explicitly so the style is consistent on files outside a repo.
        if ! _has_config "$_filedir" ".clang-format" &&
          ! _has_config "$_filedir" "_clang-format" &&
          [ -f "$AUTOFORMAT_DIR/clang-format" ]; then
          args=(-style="file:$AUTOFORMAT_DIR/clang-format")
        fi
        _run_fmt clang-format -i "${args[@]}" "$file"
      fi
      ;;
    lua)
      if command -v stylua &>/dev/null; then
        args=()
        # stylua treats both stylua.toml and .editorconfig as style
        # sources. Respect either one before applying the personal
        # fallback, because CLI --config-path would otherwise win.
        if ! _has_config "$_filedir" "stylua.toml" &&
          ! _has_config "$_filedir" ".stylua.toml" &&
          ! _has_config "$_filedir" ".editorconfig" &&
          [ -f "$AUTOFORMAT_DIR/stylua.toml" ]; then
          args=(--config-path "$AUTOFORMAT_DIR/stylua.toml")
        fi
        _run_fmt stylua "${args[@]}" "$file"
      fi
      ;;
    rs)
      if command -v rustfmt &>/dev/null; then
        args=()
        # Cargo owns the language edition for real crates. Keep using the
        # fallback rustfmt style config when no repo rustfmt.toml exists, but
        # pass Cargo's edition explicitly so direct rustfmt agrees with
        # `cargo fmt` on Rust 2024 syntax and formatting.
        cargo_edition=$(_find_cargo_edition "$_filedir" 2>/dev/null || true)
        [ -n "$cargo_edition" ] && args+=(--edition "$cargo_edition")
        # rustfmt's config walk only covers Rust's standard filenames.
        # Passing the fallback explicitly keeps standalone files aligned
        # with integration defaults while leaving repo configs untouched.
        if ! _has_config "$_filedir" "rustfmt.toml" &&
          ! _has_config "$_filedir" ".rustfmt.toml" &&
          [ -f "$AUTOFORMAT_DIR/rustfmt.toml" ]; then
          args+=(--config-path "$AUTOFORMAT_DIR/rustfmt.toml")
        fi
        _run_fmt rustfmt "${args[@]}" "$file"
      fi
      ;;
    rb)
      _format_ruby "$file" "$_filedir"
      ;;
    php)
      _format_php "$file" "$_filedir"
      ;;
    toml)
      if command -v taplo &>/dev/null; then
        args=()
        # taplo walks from the process cwd (not the file path) when
        # auto-discovering its config, so detect the per-repo config
        # ourselves and pass it explicitly via --config. Falls back to
        # our global default when no per-repo config is present.
        repo_cfg=$(_find_config "$_filedir" "taplo.toml" 2>/dev/null ||
          _find_config "$_filedir" ".taplo.toml" 2>/dev/null || true)
        if [ -n "$repo_cfg" ]; then
          args=(--config "$repo_cfg")
        elif [ -f "$AUTOFORMAT_DIR/taplo.toml" ]; then
          args=(--config "$AUTOFORMAT_DIR/taplo.toml")
        fi
        _run_fmt taplo fmt "${args[@]}" "$file"
      fi
      ;;
    css | js | jsx | json | jsonc | ts | tsx)
      if command -v biome &>/dev/null; then
        args=()
        # biome walks for biome.json(c) itself, but its walk starts from
        # the process cwd (not the file path). Detect the per-repo config
        # here and pass --config-path (a directory) explicitly. Falls back
        # to our global default when no per-repo config is present.
        #
        # Self-format guard: if the file being formatted IS the config we
        # would otherwise pass, skip the --config-path arg. Otherwise
        # biome sees the same root config twice (once via --config-path,
        # once via its own discovery walk on the input file) and errors
        # with "nested root configuration".
        repo_cfg=$(_find_config "$_filedir" "biome.json" 2>/dev/null ||
          _find_config "$_filedir" "biome.jsonc" 2>/dev/null || true)
        if [ -n "$repo_cfg" ] && [ "$repo_cfg" != "$file" ]; then
          args=(--config-path "$(dirname "$repo_cfg")")
        elif [ -f "$AUTOFORMAT_DIR/biome.json" ] &&
          [ "$file" != "$AUTOFORMAT_DIR/biome.json" ]; then
          args=(--config-path "$AUTOFORMAT_DIR")
        fi
        # `biome check --write --linter-enabled=false` runs formatter +
        # assist (organize imports etc.) but skips the linter. Autolint
        # runs `biome lint` separately — keeping these disjoint means
        # autoformat-on-save never applies a behavior-changing lint fix
        # behind the user's back.
        _run_fmt biome check --write --linter-enabled=false \
          "${args[@]}" "$file"
      fi
      ;;
    htm | html)
      if command -v superhtml &>/dev/null; then
        _run_fmt superhtml fmt "$file"
      fi
      ;;
    bzl | star)
      if command -v buildifier &>/dev/null; then
        _run_fmt buildifier "$file"
      fi
      ;;
    cmake)
      _format_cmake "$file" "$_filedir"
      ;;
    yaml | yml)
      if command -v yamlfmt &>/dev/null; then
        args=()
        # yamlfmt's own auto-discovery looks for `.yamlfmt` in the cwd
        # (not walking). Detect a per-repo `.yamlfmt` via the walk so
        # `autoformat` respects it regardless of cwd at invocation time.
        yamlfmt_cfg=$(_find_config "$_filedir" ".yamlfmt" 2>/dev/null || true)
        if [ -n "$yamlfmt_cfg" ]; then
          args=(-conf "$yamlfmt_cfg")
        elif [ -f "$AUTOFORMAT_DIR/yamlfmt.yaml" ]; then
          args=(-conf "$AUTOFORMAT_DIR/yamlfmt.yaml")
        fi
        _run_fmt yamlfmt "${args[@]}" "$file"
      fi
      ;;
    md)
      # rumdl --fix doubles as a formatter: it auto-fixes most rule
      # violations (list markers, spacing, heading styles). It isn't a
      # prose reflower like prettier; for prose reflow, rely on the
      # editor's gqq or equivalent.
      if command -v rumdl &>/dev/null; then
        args=()
        # rumdl also understands markdownlint config names, so those
        # count as repo-owned policy and suppress the fallback.
        if ! _has_config "$_filedir" ".rumdl.toml" &&
          ! _has_config "$_filedir" "rumdl.toml" &&
          ! _has_config "$_filedir" ".markdownlint.json" &&
          ! _has_config "$_filedir" ".markdownlint.jsonc" &&
          [ -f "$AUTOFORMAT_DIR/rumdl.toml" ]; then
          args=(--config "$AUTOFORMAT_DIR/rumdl.toml")
        fi
        _run_fmt rumdl check --fix "${args[@]}" "$file"
      fi
      ;;
    *)
      # Extensionless files: dispatch via _classify_shell (dotfile name or shebang).
      case "$(_classify_shell "$file")" in
        zsh)
          if command -v shfmt &>/dev/null; then
            _format_sh "$file" "$_filedir" "zsh"
          fi
          ;;
        bash)
          if command -v shfmt &>/dev/null; then
            _format_sh "$file" "$_filedir"
          fi
          ;;
      esac
      ;;
  esac
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

  AUTOFORMAT_DIR="${AUTOFORMAT_DIR:-$HOME/.config/autoformat}"

  # Resolve relative AUTOFORMAT_DIR values at startup. Formatter branches
  # pass fallback configs directly to tools, and some tools resolve those
  # paths after changing cwd or walking from cwd instead of from the file.
  if [ -d "$AUTOFORMAT_DIR" ]; then
    AUTOFORMAT_DIR=$(_abs_dir "$AUTOFORMAT_DIR")
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
