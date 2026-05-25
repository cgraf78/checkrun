# shellcheck shell=bash
# shellcheck disable=SC2154
# GitHub Actions lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `json` flag.

_lint_zizmor() {
  local file="$1"
  command -v zizmor &>/dev/null || return 0

  if [ "$json" -eq 1 ]; then
    local out tool_rc
    out=$(zizmor --offline --no-progress --quiet --format json "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        def one_based($v): if $v == null then null else ($v + 1) end;
        (if type == "array" then .[] else .findings[]? end) as $finding |
        ($finding.locations[0].concrete.location // {}) as $loc |
        (($loc.span // $finding.locations[0].span // {}) as $span |
        {
          path: $path,
          line: ($span.start.line // one_based($loc.start_point.row) // $finding.line // 1),
          col: ($span.start.column // one_based($loc.start_point.column) // $finding.column // 1),
          end_line: ($span.end.line // one_based($loc.end_point.row) // $finding.end_line),
          end_col: ($span.end.column // one_based($loc.end_point.column) // $finding.end_column),
          severity: sev($finding.severity // $finding.determinations.severity),
          code: ($finding.ident // $finding.kind // $finding.code // "zizmor"),
          message: ($finding.desc // $finding.message // "GitHub Actions security finding"),
          source: "zizmor"
        })'
    fi
    return "$tool_rc"
  fi

  local out tool_rc
  out=$(zizmor --offline --no-progress --quiet "$file" 2>&1)
  tool_rc=$?
  if [ "$tool_rc" -ne 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
  return "$tool_rc"
}

_lint_actionlint() {
  local file="$1" out tool_rc
  command -v actionlint &>/dev/null || return 0

  if [ "$json" -eq 1 ]; then
    out=$(actionlint -format '{{json .}}' "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        .[]? | {
          path: $path,
          line: .line,
          col: .column,
          end_col: .end_column,
          severity: "error",
          code: .kind,
          message: .message,
          source: "actionlint"
        }'
    fi
    return "$tool_rc"
  fi

  actionlint "$file"
}

_lint_github_workflow() {
  local file="$1" rc=0

  # Kept as a compatibility helper for direct/internal callers. Registry-backed
  # autolint dispatch now selects `actionlint` and `zizmor` as separate adapter
  # steps so explain, plan, and execution show the same path-scoped tools.
  case "$file" in
    */.github/workflows/*) ;;
    *) return 0 ;;
  esac

  _lint_actionlint "$file" || rc=$?
  _lint_zizmor "$file" || rc=$?
  return "$rc"
}
