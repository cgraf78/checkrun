# shellcheck shell=bash
# shellcheck disable=SC2154
# Build-system and container lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `fix`/`json`
# flags instead of maintaining their own global option state.

_lint_buildifier() {
  local file="$1"
  command -v buildifier &>/dev/null || return 0
  if [ "$json" -eq 1 ]; then
    local out err_out tool_rc
    # buildifier writes parse errors to stderr but lint warnings to JSON stdout.
    # Keep both paths visible in unified JSON mode.
    err_out=$(mktemp 2>/dev/null || echo "")
    if [ -n "$err_out" ]; then
      out=$(buildifier --lint=warn --format=json --mode=check "$file" 2>"$err_out")
    else
      out=$(buildifier --lint=warn --format=json --mode=check "$file" 2>/dev/null)
    fi
    tool_rc=$?
    local has_warnings=0
    if [ -n "$out" ]; then
      local warn_json
      warn_json=$(printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        .files[]?.warnings[]? | {
          path: $path,
          line: .start.line,
          col: .start.column,
          end_line: .end.line,
          end_col: .end.column,
          severity: "warning",
          code: .category,
          message: .message,
          source: "buildifier"
        }')
      if [ -n "$warn_json" ]; then
        printf '%s\n' "$warn_json"
        has_warnings=1
      fi
    fi
    if [ "$tool_rc" -ne 0 ] && [ "$has_warnings" -eq 0 ] && [ -n "$err_out" ] && [ -s "$err_out" ]; then
      local msg
      msg=$(head -1 "$err_out")
      _emit_synth_error "$file" "$msg" "buildifier"
    fi
    [ -n "$err_out" ] && rm -f "$err_out"
    [ "$tool_rc" -ne 0 ] && return "$tool_rc"
    return 0
  fi
  if [ "$fix" -eq 1 ]; then
    buildifier --lint=fix "$file"
  else
    buildifier --lint=warn --mode=check "$file"
  fi
}

_lint_checkmake() {
  local file="$1" dir="$2" config_path="${4:-}"
  command -v checkmake &>/dev/null || return 0

  local args=()
  # Run from the Makefile directory so include paths and target names match a
  # developer's manual invocation. Config paths are resolved by the registry
  # before this adapter changes cwd.
  [ -n "$config_path" ] && args=(--config "$config_path")

  if [ "$json" -eq 1 ]; then
    local out tool_rc
    out=$(cd "$dir" && checkmake --output json ${args[@]+"${args[@]}"} "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" '.[]? | {
        path: $path,
        line: (.line_number // 1),
        col: 1,
        severity: "warning",
        code: .rule,
        message: .violation,
        source: "checkmake"
      }'
    fi
    return "$tool_rc"
  fi

  (cd "$dir" && checkmake ${args[@]+"${args[@]}"} "$file")
}

_lint_cmake() {
  local file="$1" config_path="${4:-}" args=()
  command -v cmake-lint &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config-files "$config_path")
  _lint_text_command "cmake-lint" "$file" cmake-lint ${args[@]+"${args[@]}"} "$file"
}

_lint_dockerfile() {
  local file="$1" config_path="${4:-}" rc=0 out tool_rc
  local args=()

  command -v hadolint &>/dev/null || return 0
  # hadolint does not look in the global fallback directory on its own, but a
  # repo .hadolint.yaml should always win over the personal fallback. The
  # registry owns that choice now; the adapter only translates it to hadolint's
  # CLI flag.
  [ -n "$config_path" ] && args=(-c "$config_path")

  if [ "$json" -eq 1 ]; then
    out=$(hadolint --format=json ${args[@]+"${args[@]}"} "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ] && [ "$out" != "[]" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        .[]? | {
          path: $path,
          line: .line,
          col: .column,
          severity: sev(.level),
          code: .code,
          message: .message,
          source: "hadolint"
        }'
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  else
    hadolint ${args[@]+"${args[@]}"} "$file" || rc=$?
  fi

  return "$rc"
}
