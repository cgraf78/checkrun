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

_checkrun_config_dir() {
  local dir
  if [ -n "${CHECKRUN_CONFIG_DIR:-}" ]; then
    dir="$CHECKRUN_CONFIG_DIR"
  else
    case "${XDG_CONFIG_HOME:-}" in
      /*) dir="${XDG_CONFIG_HOME%/}/checkrun" ;;
      *)
        if [ -z "${HOME:-}" ]; then
          printf 'checkrun: HOME is required when XDG_CONFIG_HOME is unset or relative\n' >&2
          return 1
        fi
        dir="$HOME/.config/checkrun"
        ;;
    esac
  fi

  # Resolve existing relative roots once at process startup. Backends may run
  # from package directories or tool-specific cwd choices, so config paths must
  # already be cwd-independent before planning hands them to adapters.
  if [ -d "$dir" ]; then
    _abs_dir "$dir"
  else
    printf '%s\n' "$dir"
  fi
}

_checkrun_python_usable() {
  local python="$1" probe="${2:-import tomllib}"

  # Callers choose the import probe that matches their dependency floor. The
  # registry needs stdlib `tomllib`, while maintenance helpers that only use
  # older stdlib modules should not reject otherwise-good Python 3 installs.
  [ -x "$python" ] || return 1
  "$python" -c "$probe" >/dev/null 2>&1
}

_checkrun_python() {
  local candidate resolved probe="${1:-import tomllib}"

  # Hooks and tests often constrain PATH to prove missing formatter/linter
  # behavior. Python entry points still need an interpreter in those
  # environments, so do not rely solely on `/usr/bin/env python3` from script
  # shebangs.
  if [ -n "${CHECKRUN_PYTHON:-}" ] && _checkrun_python_usable "$CHECKRUN_PYTHON" "$probe"; then
    printf '%s\n' "$CHECKRUN_PYTHON"
    return 0
  fi

  for candidate in python3 /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    case "$candidate" in
      */*)
        _checkrun_python_usable "$candidate" "$probe" || continue
        printf '%s\n' "$candidate"
        return 0
        ;;
      *)
        if command -v "$candidate" >/dev/null 2>&1; then
          resolved=$(command -v "$candidate")
          _checkrun_python_usable "$resolved" "$probe" || continue
          printf '%s\n' "$resolved"
          return 0
        fi
        ;;
    esac
  done

  return 1
}

_checkrun_registry() {
  local python
  python=$(_checkrun_python) || {
    echo "checkrun: python3 with tomllib is required for registry planning" >&2
    return 127
  }
  "$python" "$CHECKRUN_LIB_DIR/registry.py" "$@"
}

_checkrun_tempfile() {
  local tmp i

  if command -v mktemp >/dev/null 2>&1; then
    mktemp "${TMPDIR:-/tmp}/checkrun-plan.XXXXXX"
    return $?
  fi

  # Some tests and hook launchers deliberately constrain PATH to only the tool
  # being exercised. Registry execution still needs a scratch file so callers
  # can capture Python's exit status before reading the NUL-delimited plan. Use
  # Bash's noclobber mode as a mktemp fallback instead of making minimal PATHs
  # fail only because the temp-file helper is missing.
  for i in {1..20}; do
    tmp="${TMPDIR:-/tmp}/checkrun-plan.$$.$RANDOM.$i"
    if (
      set -C
      : >"$tmp"
    ) 2>/dev/null; then
      printf '%s\n' "$tmp"
      return 0
    fi
  done

  return 1
}

_checkrun_remove() {
  # Cleanup should never become user-visible lint noise. Minimal PATH tests may
  # omit `rm` on purpose, and a stale private temp file is less harmful than
  # printing an infrastructure error after a deliberately skipped lint plan.
  if command -v rm >/dev/null 2>&1; then
    rm -f "$@"
  fi
}

# Walk up from the file's directory looking for a config file and print its
# absolute path on success. `$root` is an inclusive stop point: configs at
# `$root/$name` still count. Tracks `prev` so the loop terminates even when
# `dir` is relative (e.g. "."), where dirname would otherwise never shrink
# toward root. The absolute output is intentional: some callers run the tool
# from a different cwd after resolving the config.
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

# Phase-specific ignore files let policy say "do not format", "do not
# spellcheck", or "do not run the language/backend linter" without accidentally
# suppressing schema validation. The legacy `ignore` file remains an all-phase
# skip for compatibility with existing installs and test fixtures.
_ignored_for() {
  local phase="$1" file="$2" config_dir="$3" phase_file

  _ignored "$file" "$config_dir/ignore" && return 0

  case "$phase" in
    format) phase_file="format-ignore" ;;
    lint) phase_file="lint-ignore" ;;
    spell) phase_file="spell-ignore" ;;
    schema) phase_file="schema-ignore" ;;
    tool) phase_file="tool-ignore" ;;
    *) phase_file="$phase-ignore" ;;
  esac

  _ignored "$file" "$config_dir/$phase_file"
}
