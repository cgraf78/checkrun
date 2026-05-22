# shellcheck shell=bash
# shellcheck disable=SC2154
# Documentation and prose lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `fix`/`json`
# flags instead of maintaining their own global option state.

_lint_typos() {
  local file="$1" dir="$2"
  command -v typos &>/dev/null || return 0

  local args=()
  local repo_cfg
  repo_cfg=$(_find_config "$dir" ".typos.toml" 2>/dev/null ||
    _find_config "$dir" "typos.toml" 2>/dev/null || true)
  if [ -n "$repo_cfg" ]; then
    args=(--config "$repo_cfg")
  elif [ -f "$AUTOLINT_DIR/typos.toml" ]; then
    args=(--config "$AUTOLINT_DIR/typos.toml")
  fi

  if [ "$json" -eq 1 ]; then
    local out tool_rc
    out=$(typos --format json "${args[@]}" "$file" 2>/dev/null)
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
    typos --write-changes "${args[@]}" "$file"
  else
    typos "${args[@]}" "$file"
  fi
}

_lint_rumdl() {
  local file="$1" dir="$2" rc=0 out tool_rc
  local args=()

  command -v rumdl &>/dev/null || return 0
  # rumdl reads markdownlint configs for compatibility, so both naming families
  # count as repo-owned policy and suppress the personal fallback.
  if ! _has_config "$dir" ".rumdl.toml" &&
    ! _has_config "$dir" "rumdl.toml" &&
    ! _has_config "$dir" ".markdownlint.json" &&
    ! _has_config "$dir" ".markdownlint.jsonc" &&
    [ -f "$AUTOLINT_DIR/rumdl.toml" ]; then
    args=(--config "$AUTOLINT_DIR/rumdl.toml")
  fi

  if [ "$json" -eq 1 ]; then
    out=$(rumdl check --output json "${args[@]}" "$file" 2>/dev/null)
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
    rumdl check --fix "${args[@]}" "$file" || rc=$?
  else
    rumdl check --quiet "${args[@]}" "$file" || rc=$?
  fi

  return "$rc"
}
