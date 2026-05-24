# shellcheck shell=bash
# Shared helpers for autoformat/autolint dispatch.
#
# Kept minimal: the helpers must stay safe to source under `set -u`
# (the defaults used by both callers) and must not define any globals
# beyond the helper functions themselves.
#
# The `_toml_*` helpers require `yq` on PATH. Callers enforce that
# before invoking any helper that can parse TOML; this file does not
# re-check at source time because that would run on every edit-hook
# fire even for no-op paths.

# Resolve an existing directory relative to the caller's current cwd.
# Callers use this once for fallback config roots so every later
# `--config` argument survives tools that `cd` before execution.
_abs_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  (cd "$dir" && pwd)
}

# Resolve a path without requiring GNU `readlink -f` and without
# canonicalizing symlinks. These scripts treat the user-provided file
# path as the identity surfaced in diagnostics, so only the directory
# prefix is made cwd-independent.
_abs_path() {
  local path="$1" dir base

  case "$path" in
    */*)
      dir="${path%/*}"
      base="${path##*/}"
      [ -n "$dir" ] || dir=/
      ;;
    *)
      dir=.
      base="$path"
      ;;
  esac

  local absdir
  absdir=$(_abs_dir "$dir") || return 1
  if [ "$absdir" = "/" ]; then
    printf '/%s\n' "$base"
  else
    printf '%s/%s\n' "$absdir" "$base"
  fi
}

# Walk up from the file's directory looking for a config file. `$root`
# is an inclusive stop point: configs at `$root/$name` still count.
# Tracks `prev` so the loop terminates even when `dir` is relative
# (e.g. "."), where dirname would otherwise never shrink toward root.
_has_config() {
  local dir="$1" name="$2" root="${3:-/}" prev=""
  while [ "$dir" != "$prev" ]; do
    [ -f "$dir/$name" ] && return 0
    [ "$dir" = "$root" ] && break
    prev="$dir"
    dir=$(dirname "$dir")
  done
  return 1
}

# Like `_has_config`, but prints the absolute path of the found
# config on success. Useful when a tool's own config discovery
# differs from our walk semantics and we need to pass the path
# through explicitly via `--config <path>`. The absolute output is
# intentional: some callers run the tool from a different cwd after
# resolving the config.
_find_config() {
  local dir="$1" name="$2" root="${3:-/}" prev=""
  while [ "$dir" != "$prev" ]; do
    if [ -f "$dir/$name" ]; then
      _abs_path "$dir/$name"
      return 0
    fi
    [ "$dir" = "$root" ] && break
    prev="$dir"
    dir=$(dirname "$dir")
  done
  return 1
}

# cmakelang shares one config file family between cmake-format and
# cmake-lint. Keep the search order in one helper so the formatter and
# linter cannot disagree about which policy file owns a CMake source.
_find_cmake_config() {
  local dir="$1" fallback_dir="${2:-}" cfg

  cfg=$(_find_config "$dir" ".cmake-format.py" 2>/dev/null ||
    _find_config "$dir" "cmake-format.py" 2>/dev/null ||
    _find_config "$dir" ".cmake-format.yaml" 2>/dev/null ||
    _find_config "$dir" "cmake-format.yaml" 2>/dev/null ||
    _find_config "$dir" ".cmake-format.json" 2>/dev/null ||
    _find_config "$dir" "cmake-format.json" 2>/dev/null || true)
  if [ -n "$cfg" ]; then
    printf '%s\n' "$cfg"
    return 0
  fi

  if [ -n "$fallback_dir" ] && [ -f "$fallback_dir/cmake-format.py" ]; then
    _abs_path "$fallback_dir/cmake-format.py"
    return 0
  fi

  return 1
}

_find_rubocop_config() {
  local dir="$1" fallback_dir="${2:-}" cfg

  cfg=$(_find_config "$dir" ".rubocop.yml" 2>/dev/null ||
    _find_config "$dir" ".rubocop.yaml" 2>/dev/null ||
    _find_config "$dir" "rubocop.yml" 2>/dev/null ||
    _find_config "$dir" "rubocop.yaml" 2>/dev/null || true)
  if [ -n "$cfg" ]; then
    printf '%s\n' "$cfg"
    return 0
  fi

  if [ -n "$fallback_dir" ] && [ -f "$fallback_dir/rubocop.yml" ]; then
    _abs_path "$fallback_dir/rubocop.yml"
    return 0
  fi

  return 1
}

_find_php_cs_fixer_config() {
  local dir="$1" fallback_dir="${2:-}" cfg

  cfg=$(_find_config "$dir" ".php-cs-fixer.php" 2>/dev/null ||
    _find_config "$dir" ".php-cs-fixer.dist.php" 2>/dev/null || true)
  if [ -n "$cfg" ]; then
    printf '%s\n' "$cfg"
    return 0
  fi

  if [ -n "$fallback_dir" ] && [ -f "$fallback_dir/php-cs-fixer.php" ]; then
    _abs_path "$fallback_dir/php-cs-fixer.php"
    return 0
  fi

  return 1
}

_find_cargo_edition() {
  local dir="$1" manifest edition workspace_edition prev=""

  # Walk from the formatted file's directory toward the filesystem root and
  # return the first Cargo edition that can be trusted. This intentionally
  # mirrors how a source file belongs to the nearest crate/workspace instead of
  # relying on the editor or shell cwd, which can point at a parent project or a
  # long-lived agent's unrelated working directory.
  while [ "$dir" != "$prev" ]; do
    manifest="$dir/Cargo.toml"
    if [ -f "$manifest" ]; then
      # Rust edition is language context, not formatter style. The global
      # rustfmt fallback config should own width/indent policy, while Cargo owns
      # the parser/edition choice so direct rustfmt matches `cargo fmt`.
      edition=$(yq -p toml -r '.package.edition // ""' "$manifest" 2>/dev/null) || edition=""
      case "$edition" in
        2015 | 2018 | 2021 | 2024)
          printf '%s\n' "$edition"
          return 0
          ;;
      esac
      # Workspace-inherited editions are common in multi-crate repos. If a
      # member manifest says `edition.workspace = true`, keep walking upward
      # until the workspace root exposes `[workspace.package].edition`.
      if [ "$edition" = "workspace" ] ||
        [ "$(yq -p toml -r '.package.edition.workspace // ""' "$manifest" 2>/dev/null)" = "true" ]; then
        workspace_edition=$(
          yq -p toml -r '.workspace.package.edition // ""' "$manifest" 2>/dev/null
        ) || workspace_edition=""
        case "$workspace_edition" in
          2015 | 2018 | 2021 | 2024)
            printf '%s\n' "$workspace_edition"
            return 0
            ;;
        esac
      fi
    fi

    # Missing/unsupported edition is not fatal: rustfmt can still run with its
    # own default edition, and autoformat should not block non-standard or
    # partial Cargo manifests just because we could not infer this extra context.
    [ "$dir" = "/" ] && break
    prev="$dir"
    dir=$(dirname "$dir")
  done
  return 1
}

# Classify an extensionless file by dotfile-name or shebang. Prints one
# of: zsh | bash | skip | unknown. Callers decide what to do with each.
# `.profile` and direnv files are classified as bash because shfmt has
# no POSIX default mode that differs meaningfully, and direnv evaluates
# `.envrc` with bash.
_classify_shell() {
  local file="$1" base first
  base="${file##*/}"

  case "$base" in
    .zshenv | .zshrc | .zprofile | .zlogin | .zlogout)
      printf 'zsh\n'
      return 0
      ;;
    .bashrc | .bash_profile | .profile | .envrc | envrc | envrc-*)
      printf 'bash\n'
      return 0
      ;;
    Makefile | Dockerfile)
      printf 'skip\n'
      return 0
      ;;
  esac

  # Skip binary files before reading — otherwise `head -n1` on a
  # binary (e.g. `.gif` that fell through to the extensionless path)
  # leaks null bytes through command substitution, and bash warns.
  # `grep -I` returns non-zero when $file is detected as binary.
  if ! grep -Iq '' "$file" 2>/dev/null; then
    printf 'unknown\n'
    return 0
  fi

  first=$(head -n1 "$file" 2>/dev/null) || true
  if printf '%s\n' "$first" | grep -qE '^#!.*\bzsh\b'; then
    printf 'zsh\n'
  elif printf '%s\n' "$first" | grep -qE '^#!.*\b(bash|sh)\b'; then
    printf 'bash\n'
  else
    printf 'unknown\n'
  fi
}

# Read multiple keys from a TOML file in a single `yq` invocation.
# Prints one line per requested key, in order; missing/null keys print
# as an empty line so callers can parse with sequential `read` calls.
# Collapsing N lookups into 1 subprocess matters for hook latency.
_toml_read_keys() {
  local file="$1"
  shift
  local expr="" k
  for k in "$@"; do
    [ -n "$expr" ] && expr="$expr, "
    expr="$expr.$k // \"\""
  done
  yq -p toml "$expr" "$file" 2>/dev/null
}

# Walk up from $dir looking for a $filename whose content (parsed by
# yq in the given $format: `toml` or `json`) satisfies the yq
# predicate. Returns 0 on first match. Tracks `prev` to terminate on
# relative paths, same as `_has_config`.
#
# Used to detect per-repo configs that live INSIDE a multi-purpose
# file — pyproject.toml with a `[tool.ruff]` section, package.json
# with a `prettier` key, etc. The caller writes the predicate
# themselves so hyphenated keys / nested paths / `//` coalescing are
# all supported uniformly:
#
#   _walk_config_with_key "$_filedir" pyproject.toml toml \
#     '.tool.ruff // .tool.ruff.format'
#   _walk_config_with_key "$_filedir" package.json json '.prettier'
#   _walk_config_with_key "$_filedir" package.json json \
#     '."markdownlint-cli2"'
_walk_config_with_key() {
  local dir="$1" filename="$2" format="$3" predicate="$4" prev=""
  while [ "$dir" != "$prev" ]; do
    if [ -f "$dir/$filename" ] &&
      yq -p "$format" -e "$predicate" "$dir/$filename" >/dev/null 2>&1; then
      return 0
    fi
    [ "$dir" = "/" ] && break
    prev="$dir"
    dir=$(dirname "$dir")
  done
  return 1
}

# Check whether a file is listed in an ignore file. Returns 0 (ignored) if any
# non-blank non-comment line is a bash glob pattern that matches the file path.
# Returns 1 otherwise, including when the ignore file doesn't exist.
#
# Pattern semantics: plain bash globs — `*`, `?`, `[...]` — matched
# against the absolute file path. No `**`, no negations, no
# gitignore-style directory anchoring. Basename-only ignores should
# use a leading directory glob, e.g. `*/generated.py`.
_ignored() {
  local file="$1" ignorefile="$2" pattern
  [ -f "$ignorefile" ] || return 1
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in
      '' | \#*) continue ;;
    esac
    # shellcheck disable=SC2053  # pattern is intentionally unquoted for glob
    [[ "$file" == $pattern ]] && return 0
  done <"$ignorefile"
  return 1
}

# Phase-specific ignore files let policy say "do not format" or "do not
# spellcheck" without accidentally suppressing schema validation. The legacy
# `ignore` file remains an all-phase skip for compatibility with existing
# installs and test fixtures.
_ignored_for() {
  local phase="$1" file="$2" config_dir="$3" phase_file

  _ignored "$file" "$config_dir/ignore" && return 0

  case "$phase" in
    format) phase_file="format-ignore" ;;
    lint) phase_file="lint-ignore" ;;
    spell) phase_file="spell-ignore" ;;
    schema) phase_file="schema-ignore" ;;
    *) phase_file="$phase-ignore" ;;
  esac

  _ignored "$file" "$config_dir/$phase_file"
}
