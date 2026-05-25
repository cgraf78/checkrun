# shellcheck shell=bash
# shellcheck disable=SC2154
# Documentation and prose lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `fix`/`json`
# flags instead of maintaining their own global option state.

_lint_typos() {
  local file="$1" config_path="${4:-}"
  command -v typos &>/dev/null || return 0

  local args=()
  # The registry selects project or fallback spelling policy once. Typos accepts
  # both through the same flag, so execution should not repeat its own walk.
  [ -n "$config_path" ] && args=(--config "$config_path")

  if [ "$json" -eq 1 ]; then
    local out tool_rc
    out=$(typos --format json ${args[@]+"${args[@]}"} "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" '
        select(.type == "typo" or .typo) | {
          path: $path,
          line: (.line_num // .line_number // .line // 1),
          col: ((.byte_offset // .column // .col // 0) + 1),
          severity: "warning",
          code: (.typo // .word // "typo"),
          message: (
            if (.typo and .corrections) then
              "Possible typo: " + (.typo|tostring) + " -> " + (.corrections | join(", "))
            elif .message then
              .message
            elif .typo then
              "Possible typo: " + (.typo|tostring)
            else
              "Possible typo"
            end
          ),
          source: "typos"
        }'
    fi
    return "$tool_rc"
  fi

  if [ "$fix" -eq 1 ]; then
    typos --write-changes ${args[@]+"${args[@]}"} "$file"
  else
    typos ${args[@]+"${args[@]}"} "$file"
  fi
}

_lint_rumdl() {
  local file="$1" config_path="${4:-}" rc=0 out tool_rc
  local args=()

  command -v rumdl &>/dev/null || return 0
  # rumdl reads markdownlint configs for compatibility, so both naming families
  # are registered in the policy. Use the registry-selected path directly so
  # plan/explain and execution cannot choose different config files.
  [ -n "$config_path" ] && args=(--config "$config_path")

  if [ "$json" -eq 1 ]; then
    out=$(rumdl check --output json ${args[@]+"${args[@]}"} "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        .[]? | {
          path: $path,
          line: .line,
          col: .column,
          severity: sev(.severity),
          code: .rule,
          message: .message,
          source: "rumdl"
        }'
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  elif [ "$fix" -eq 1 ]; then
    rumdl check --fix ${args[@]+"${args[@]}"} "$file" || rc=$?
  else
    rumdl check --quiet ${args[@]+"${args[@]}"} "$file" || rc=$?
  fi

  return "$rc"
}
