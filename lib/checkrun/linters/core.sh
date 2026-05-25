# shellcheck shell=bash
# shellcheck disable=SC2154
# Core helpers shared by linter adapters.
#
# Adapter helpers are called below `_autolint_main`, so Bash dynamic scoping lets
# them read the current invocation's local `json` flag without global state.

# Severity normalizer shared by jq filters below: maps each tool's native level
# spelling onto {error, warning, info, hint}. Unknown values fall back to warning
# so a missing severity never silently drops a diagnostic.
# shellcheck disable=SC2016  # single quotes intentional: this is a jq program
_JQ_SEVLIB='def sev($v):
  ({
    "error":"error","err":"error","fatal":"error",
    "warning":"warning","warn":"warning",
    "info":"info","information":"info","note":"info",
    "hint":"hint","style":"hint"
  })[($v // "warning") | ascii_downcase] // "warning";'

_lintable_path() {
  local file="$1"

  [ -z "$file" ] && return 1
  [ -f "$file" ] || return 1

  # Normalize before planning so editor, hook, and CLI callers all apply the
  # same absolute-path policy even when they pass relative filenames. Ignore
  # decisions live in the registry planner now; keeping them out of this prefilter
  # lets lint-ignore, spell-ignore, schema-ignore, and tool-ignore share one
  # source of truth with `checkrun plan` and `checkrun explain`.
  file=$(_abs_path "$file") || return 1

  printf '%s\n' "$file"
}

# Emit a synthesized error-level diagnostic for tools with no structured output.
# This keeps JSON mode useful even when a backend can only report file-level
# failure details.
_emit_synth_error() {
  local path="$1" message="$2" source_="$3"
  jq -cn --arg p "$path" --arg m "$message" --arg s "$source_" '{
    path: $p, line: 1, col: 1, severity: "error", message: $m, source: $s
  }'
}

_lint_text_command() {
  local source_="$1" file="$2"
  shift 2

  local out tool_rc msg
  out=$("$@" 2>&1)
  tool_rc=$?
  if [ "$tool_rc" -ne 0 ]; then
    if [ "$json" -eq 1 ]; then
      msg=$(printf '%s\n' "$out" | sed -n '1p')
      _emit_synth_error "$file" "${msg:-"$source_ check failed"}" "$source_"
    elif [ -n "$out" ]; then
      printf '%s\n' "$out"
    fi
  fi
  return "$tool_rc"
}
