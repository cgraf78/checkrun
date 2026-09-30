# shellcheck shell=bash
# shellcheck disable=SC2154
# Documentation and prose lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `fix`/`json`
# flags instead of maintaining their own global option state.

_typos_status() {
  # Translate a typos exit status into Checkrun's lint contract. typos-cli
  # (verified against 1.50) exits 2 when it finds misspellings, 1 for per-file
  # I/O errors, 64 for usage errors such as a missing path, and 78 for an
  # invalid config. Passing that through would make every ordinary misspelling
  # look like Checkrun's rc 2 tool failure, which outranks rc 1 findings in
  # multi-file runs and reads as "unavailable" to Sley. Signal statuses stay
  # untouched so interruption remains distinguishable from a tool failure.
  case "$1" in
    0) return 0 ;;
    2) return 1 ;;
  esac
  [ "$1" -gt 128 ] && return "$1"
  return 2
}

_lint_typos() {
  # Positional contract from _lint_dispatch: $1 file, $2 dir, $3 config_source,
  # $4 config_path. typos accepts a single --config regardless of source.
  local file="$1" _dir="$2" _config_source="$3" config_path="${4:-}" tool_rc
  command -v typos &>/dev/null || return 0

  local args=()
  # The registry selects project or fallback spelling policy once. Typos accepts
  # both through the same flag, so execution should not repeat its own walk.
  [ -n "$config_path" ] && args=(--config "$config_path")

  if [ "$json" -eq 1 ]; then
    local out err_file msg status
    # Keep stderr out of the JSON stream, but hold it so a tool failure can
    # still explain itself below. A missing scratch file only loses that text.
    err_file=$(_checkrun_tempfile 2>/dev/null) || err_file=""
    out=$(typos --format json ${args[@]+"${args[@]}"} "$file" 2>"${err_file:-/dev/null}")
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
    _typos_status "$tool_rc"
    status=$?
    if [ "$status" -eq 2 ]; then
      # A tool failure has no typo records, so JSON consumers would otherwise
      # see rc 2 with no diagnostic. Prefer typos' own structured error record
      # (per-file I/O errors); config and usage errors only reach stderr.
      msg=$(printf '%s' "$out" | jq -rs 'map(select(.type == "error") | .msg) | first // empty' 2>/dev/null)
      [ -z "$msg" ] && [ -s "$err_file" ] && IFS= read -r msg <"$err_file"
      _emit_synth_error "$file" "${msg:-"typos failed with exit $tool_rc"}" "typos"
    fi
    [ -n "$err_file" ] && rm -f "$err_file" 2>/dev/null
    return "$status"
  fi

  if [ "$fix" -eq 1 ]; then
    typos --write-changes ${args[@]+"${args[@]}"} "$file"
  else
    typos ${args[@]+"${args[@]}"} "$file"
  fi
  tool_rc=$?
  _typos_status "$tool_rc"
}

_lint_typos_clean_batch() {
  local _config_source="$1" config_path="$2"
  local args=()
  shift 2
  command -v typos &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config "$config_path")
  typos ${args[@]+"${args[@]}"} "$@"
}

_lint_rumdl() {
  # Positional contract from _lint_dispatch: $1 file, $2 dir, $3 config_source,
  # $4 config_path. rumdl uses one --config regardless of source.
  local file="$1" _dir="$2" _config_source="$3" config_path="${4:-}" rc=0 out tool_rc
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
