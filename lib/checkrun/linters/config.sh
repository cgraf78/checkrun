# shellcheck shell=bash
# shellcheck disable=SC2154
# Config, schema, and data-file lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `json` flag.

_lint_crontab() {
  local file="$1" out tool_rc msg
  command -v crontab &>/dev/null || return 0

  out=$(crontab -T "$file" 2>&1)
  tool_rc=$?
  if [ "$tool_rc" -ne 0 ] &&
    printf '%s\n' "$out" | grep -qiE 'invalid option|illegal option|usage:'; then
    return 0
  fi
  if [ "$tool_rc" -ne 0 ]; then
    if [ "$json" -eq 1 ]; then
      msg=$(printf '%s\n' "$out" | sed -n '1p')
      _emit_synth_error "$file" "${msg:-"crontab check failed"}" "crontab"
    elif [ -n "$out" ]; then
      printf '%s\n' "$out"
    fi
  fi
  return "$tool_rc"
}

_lint_tmux_config() {
  local file="$1" out tool_rc msg
  command -v tmux &>/dev/null || return 0

  out=$(tmux source-file -n "$file" 2>&1)
  tool_rc=$?
  if [ "$tool_rc" -ne 0 ] &&
    printf '%s\n' "$out" | grep -qiE 'unknown flag -n|invalid option'; then
    return 0
  fi
  if [ "$tool_rc" -ne 0 ]; then
    if [ "$json" -eq 1 ]; then
      msg=$(printf '%s\n' "$out" | sed -n '1p')
      _emit_synth_error "$file" "${msg:-"tmux check failed"}" "tmux"
    elif [ -n "$out" ]; then
      printf '%s\n' "$out"
    fi
  fi
  return "$tool_rc"
}

_lint_git_config() {
  local file="$1"
  command -v git &>/dev/null || return 0
  _lint_text_command "git config" "$file" git config --file "$file" --list
}

# Memoize the resolved editorconfig-checker binary per shell process. The probe
# walks every PATH entry and runs `--version` on every candidate, which is
# noticeable when the same shell lints many files. The sentinel "__none__"
# distinguishes "not yet probed" from "probed and not found" so we don't repeat
# the walk just because the tool is missing.
_CHECKRUN_EC_CHECKER_CMD_CACHE=""

_editorconfig_checker_cmd() {
  if [ -n "$_CHECKRUN_EC_CHECKER_CMD_CACHE" ]; then
    [ "$_CHECKRUN_EC_CHECKER_CMD_CACHE" = "__none__" ] && return 1
    echo "$_CHECKRUN_EC_CHECKER_CMD_CACHE"
    return 0
  fi

  local candidate name path_dir

  # Version-manager shims can exist before the tool is configured. Probe every
  # candidate so a stale shim cannot mask a working binary later on PATH.
  local IFS=:
  for path_dir in $PATH; do
    [ -n "$path_dir" ] || path_dir=.
    for name in editorconfig-checker ec; do
      candidate="$path_dir/$name"
      [ -x "$candidate" ] || continue
      "$candidate" --version >/dev/null 2>&1 || continue
      _CHECKRUN_EC_CHECKER_CMD_CACHE="$candidate"
      echo "$candidate"
      return 0
    done
  done

  _CHECKRUN_EC_CHECKER_CMD_CACHE="__none__"
  return 1
}

_lint_editorconfig() {
  local file="$1" cmd
  cmd=$(_editorconfig_checker_cmd) || return 0

  # -config is for editorconfig-checker's JSON config, not the .editorconfig
  # rules file being linted, so pass the target file positionally.
  _lint_text_command "editorconfig-checker" "$file" "$cmd" "$file"
}

_lint_systemd_unit() {
  # `systemd-analyze verify` is a host-local load check: it tries to resolve the
  # unit's dependencies on THIS machine. Third-party units edited on a dev box
  # often produce false-positive errors about missing dependent units. The
  # adapter still surfaces real syntax problems; treat dependency-resolution
  # complaints as informational rather than ground truth.
  local file="$1"
  command -v systemd-analyze &>/dev/null || return 0
  _lint_text_command "systemd-analyze" "$file" systemd-analyze verify "$file"
}

_lint_schema() {
  local file="$1" validator="${CHECKRUN_SCHEMA_LINT:-${CHECKRUN_LIB_DIR:-}/schemas/schema-lint.py}"
  [ -x "$validator" ] || return 0
  command -v python3 &>/dev/null || return 0

  if [ "$json" -eq 1 ]; then
    "$validator" --json "$file"
  else
    "$validator" "$file"
  fi
}

_lint_taplo() {
  # Positional contract from _lint_dispatch: $1 file, $2 dir, $3 config_source,
  # $4 config_path. taplo wants config_source ("none" triggers --no-schema), so
  # dir is the only named-ignored local here.
  local file="$1" _dir="$2" config_source="${3:-}" config_path="${4:-}" rc=0 err tool_rc msg
  local args=()

  command -v taplo &>/dev/null || return 0
  # Three-tier: per-repo .taplo.toml -> $CHECKRUN_CONFIG_DIR/taplo.toml -> --no-schema.
  # --no-schema avoids taplo fetching the remote schema catalog on locked-down
  # hosts and on TOMLs that do not declare a schema anyway. The registry tells us
  # which tier applied; the adapter only spells the taplo CLI flags.
  if [ -n "$config_path" ]; then
    args=(--config "$config_path")
  elif [ "$config_source" = "none" ]; then
    args=(--no-schema)
  fi

  if [ "$json" -eq 1 ]; then
    # taplo has no structured output. Synthesize a minimal file-level error
    # when it reports non-zero so JSON mode still surfaces broken files.
    err=$(RUST_LOG=error taplo check ${args[@]+"${args[@]}"} "$file" 2>&1 1>/dev/null)
    tool_rc=$?
    if [ "$tool_rc" -ne 0 ]; then
      msg=${err:-"taplo check failed"}
      _emit_synth_error "$file" "$msg" "taplo"
      rc=$tool_rc
    fi
  else
    RUST_LOG=error taplo check ${args[@]+"${args[@]}"} "$file" || rc=$?
  fi

  return "$rc"
}
