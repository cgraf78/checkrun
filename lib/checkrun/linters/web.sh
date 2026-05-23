# shellcheck shell=bash
# shellcheck disable=SC2154
# Web and markup lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `fix`/`json`
# flags instead of maintaining their own global option state.

_lint_biome() {
  local file="$1" dir="$2"
  command -v biome &>/dev/null || return 0
  # Biome handles format and lint from one config. Pass the selected root
  # explicitly because discovery starts from the process cwd, not from $file.
  local args=()
  local repo_cfg
  repo_cfg=$(_find_config "$dir" "biome.json" 2>/dev/null ||
    _find_config "$dir" "biome.jsonc" 2>/dev/null || true)
  if [ -n "$repo_cfg" ] && [ "$repo_cfg" != "$file" ]; then
    args=(--config-path "$(dirname "$repo_cfg")")
  elif [ -f "$CHECKRUN_AUTOLINT_DIR/biome.json" ] &&
    [ "$file" != "$CHECKRUN_AUTOLINT_DIR/biome.json" ]; then
    args=(--config-path "$CHECKRUN_AUTOLINT_DIR")
  fi
  if [ "$json" -eq 1 ]; then
    local out tool_rc
    out=$(biome lint --reporter=json "${args[@]}" "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        .diagnostics[]? | {
          path: $path,
          line: .location.start.line,
          col: .location.start.column,
          end_line: .location.end.line,
          end_col: .location.end.column,
          severity: sev(.severity),
          code: .category,
          message: .message,
          source: "biome"
        }'
    fi
    return "$tool_rc"
  fi
  if [ "$fix" -eq 1 ]; then
    biome lint --write "${args[@]}" "$file"
  else
    biome lint "${args[@]}" "$file"
  fi
}

_lint_superhtml() {
  local file="$1" rc=0 err tool_rc diag line col msg

  command -v superhtml &>/dev/null || return 0
  if [ "$json" -eq 1 ]; then
    # superhtml check writes `file:line:col: message` to stderr, followed by
    # context and caret lines. Only parse the leading diagnostic records.
    err=$(superhtml check "$file" 2>&1 1>/dev/null)
    tool_rc=$?
    if [ "$tool_rc" -ne 0 ] && [ -n "$err" ]; then
      printf '%s\n' "$err" |
        sed $'s/\x1b\\[[0-9;]*m//g' |
        grep -E '^[^[:space:]].*:[0-9]+:[0-9]+:' |
        while IFS= read -r diag; do
          line=$(printf '%s' "$diag" | cut -d: -f2)
          col=$(printf '%s' "$diag" | cut -d: -f3)
          msg=$(printf '%s' "$diag" | cut -d: -f4- | sed 's/^ //')
          jq -cn --arg p "$file" --argjson l "$line" --argjson c "$col" --arg m "$msg" '{
            path: $p, line: $l, col: $c, severity: "error",
            message: $m, source: "superhtml"
          }'
        done
      rc=$tool_rc
    fi
  else
    superhtml check "$file" || rc=$?
  fi

  return "$rc"
}
