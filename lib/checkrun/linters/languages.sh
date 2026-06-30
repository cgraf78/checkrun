# shellcheck shell=bash
# shellcheck disable=SC2154
# Programming-language lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `fix`/`json`
# flags instead of maintaining their own global option state.

_lint_ruby() {
  # Positional contract from _lint_dispatch: $1 file, $2 dir, $3 config_source,
  # $4 config_path. rubocop's --config accepts one path regardless of source.
  local file="$1" _dir="$2" _config_source="$3" config_path="${4:-}" args=()
  command -v rubocop &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config "$config_path")
  if [ "$fix" -eq 1 ]; then
    _lint_text_command "rubocop" "$file" rubocop --autocorrect \
      ${args[@]+"${args[@]}"} "$file"
  else
    _lint_text_command "rubocop" "$file" rubocop ${args[@]+"${args[@]}"} "$file"
  fi
}

# Memoize the resolved PHP binary per shell process. Each probe spawns `php -v`
# for every candidate on PATH plus the homebrew/system fallbacks, which is the
# bulk of `_lint_php`'s cost. Sentinel "__none__" prevents repeating the probe
# when no usable PHP exists on this host.
_CHECKRUN_PHP_CLI_CACHE=""

_php_cli() {
  if [ -n "$_CHECKRUN_PHP_CLI_CACHE" ]; then
    [ "$_CHECKRUN_PHP_CLI_CACHE" = "__none__" ] && return 1
    echo "$_CHECKRUN_PHP_CLI_CACHE"
    return 0
  fi

  local candidate

  # Managed hosts can put a non-PHP compatibility shim ahead of PHP on PATH.
  # Probe every candidate so project/user PHP still wins when deliberately first.
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    "$candidate" -v 2>&1 | grep -q 'HipHop VM' && continue
    _CHECKRUN_PHP_CLI_CACHE="$candidate"
    echo "$candidate"
    return 0
  done < <(type -P -a php 2>/dev/null | awk '!seen[$0]++')

  for candidate in \
    /opt/homebrew/opt/php/bin/php \
    /usr/local/opt/php/bin/php \
    /usr/bin/php \
    /usr/local/bin/php; do
    [[ -x "$candidate" ]] || continue
    "$candidate" -v 2>&1 | grep -q 'HipHop VM' && continue
    _CHECKRUN_PHP_CLI_CACHE="$candidate"
    echo "$candidate"
    return 0
  done

  _CHECKRUN_PHP_CLI_CACHE="__none__"
  return 1
}

_lint_php() {
  local file="$1" php
  php=$(_php_cli) || return 0
  _lint_text_command "php" "$file" "$php" -l "$file"
}

_lint_java() {
  local file="$1"
  command -v google-java-format &>/dev/null || return 0
  _lint_text_command "google-java-format" "$file" \
    google-java-format --dry-run --set-exit-if-changed "$file"
}

_clang_tidy_json_diagnostics() {
  local file="$1" output="$2" emitted=0 diag loc line col rest severity msg code

  # clang-tidy has no stable JSON diagnostics. Parse only its canonical
  # `path:line:column: severity: message [check]` records so summary chatter
  # and compiler notes do not become editor diagnostics.
  while IFS= read -r diag; do
    [[ "$diag" == *"$file":* ]] || continue
    loc=${diag#*"$file":}
    line=${loc%%:*}
    rest=${loc#*:}
    col=${rest%%:*}
    rest=${rest#*:}
    case "$line:$col" in
      *[!0-9:]* | :* | *:) continue ;;
    esac
    rest=${rest# }
    severity=${rest%%:*}
    # Same-file compiler notes use the same location shape as clang-tidy
    # findings, but they are supporting context for a real warning/error. Do
    # not promote them into standalone editor diagnostics.
    case "$severity" in
      warning | error) ;;
      *) continue ;;
    esac
    rest=${rest#*:}
    msg=${rest# }
    code=""
    if [[ "$msg" == *" ["*"]" ]]; then
      code=${msg##*\[}
      code=${code%\]}
      msg=${msg%" [$code]"}
    fi
    jq -cn \
      --arg p "$file" \
      --argjson l "$line" \
      --argjson c "$col" \
      --arg sev "$severity" \
      --arg code "$code" \
      --arg m "$msg" \
      "$_JQ_SEVLIB"'
      {
        path: $p,
        line: $l,
        col: $c,
        severity: sev($sev),
        code: (if $code == "" then null else $code end),
        message: $m,
        source: "clang-tidy"
      }'
    emitted=1
  done <<<"$output"

  [ "$emitted" -eq 1 ]
}

_lint_clang_tidy() {
  local file="$1" dir="$2" config_source="${3:-}" _config_path="${4:-}"
  local clang_config compile_db compile_flags compile_root rc=0 out tool_rc
  local args=()

  command -v clang-tidy &>/dev/null || return 0
  [ "$config_source" = "none" ] && return 0

  # The registry-level config probe is the single source of truth for whether
  # clang-tidy may run at all. Once it is allowed, discover rule config and
  # compile metadata independently because projects commonly have both and
  # clang-tidy needs them on different CLI flags. A .clang-tidy file configures
  # checks, but a compile database or compile flags file is what makes the
  # per-file invocation meaningful.
  clang_config=$(_find_config "$dir" .clang-tidy 2>/dev/null || true)
  compile_db=$(_find_config "$dir" compile_commands.json 2>/dev/null || true)
  compile_flags=$(_find_config "$dir" compile_flags.txt 2>/dev/null || true)
  if [ -n "$compile_db" ]; then
    compile_root=$(dirname "$compile_db")
  elif [ -n "$compile_flags" ]; then
    compile_root=$(dirname "$compile_flags")
  else
    compile_root=""
  fi

  [ -n "$compile_root" ] || return 0
  [ -n "$clang_config" ] && args+=("--config-file=$clang_config")
  [ -n "$compile_root" ] && args+=("-p=$compile_root")

  if [ "$fix" -eq 1 ]; then
    args+=(--fix)
  fi

  out=$(clang-tidy --quiet ${args[@]+"${args[@]}"} "$file" 2>&1)
  tool_rc=$?
  if [ "$json" -eq 1 ]; then
    local parsed=1
    if [ -n "$out" ]; then
      _clang_tidy_json_diagnostics "$file" "$out"
      parsed=$?
      if [ "$parsed" -ne 0 ] && [ "$tool_rc" -ne 0 ]; then
        _emit_synth_error "$file" "$out" "clang-tidy"
      fi
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
    if [ "$rc" -eq 0 ] && [ "$parsed" -eq 0 ]; then
      rc=1
    fi
  else
    [ -n "$out" ] && printf '%s\n' "$out"
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "$file:"; then
      rc=1
    fi
  fi

  return "$rc"
}

_lint_ruff() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" rc=0 out tool_rc
  local args=()

  command -v ruff &>/dev/null || return 0
  # Project Ruff config is intentionally left native so relative paths inside
  # pyproject/ruff.toml are interpreted the same way Ruff would interpret them
  # from a manual run. The registry still owns the decision: only a selected
  # fallback path is translated into an explicit --config.
  [ "$config_source" = "fallback" ] && [ -n "$config_path" ] && args=(--config "$config_path")

  if [ "$json" -eq 1 ]; then
    out=$(ruff check --output-format=json-lines ${args[@]+"${args[@]}"} "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        select(.code) | {
          path: $path,
          line: .location.row,
          col: .location.column,
          end_line: .end_location.row,
          end_col: .end_location.column,
          severity: sev(.severity),
          code: .code,
          message: .message,
          source: "ruff"
        }'
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  elif [ "$fix" -eq 1 ]; then
    ruff check --fix ${args[@]+"${args[@]}"} "$file" || rc=$?
  else
    ruff check ${args[@]+"${args[@]}"} "$file" || rc=$?
  fi

  return "$rc"
}

_lint_selene() {
  # Positional contract from _lint_dispatch: $1 file, $2 dir, $3 config_source,
  # $4 config_path. selene takes one --config regardless of source.
  local file="$1" _dir="$2" _config_source="$3" config_path="${4:-}" rc=0 out tool_rc
  local args=()

  command -v selene &>/dev/null || return 0
  # selene discovery is cwd-sensitive, so pass the selected config explicitly.
  [ -n "$config_path" ] && args=(--config "$config_path")

  if [ "$json" -eq 1 ]; then
    out=$(selene --display-style=json2 ${args[@]+"${args[@]}"} "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      # selene emits Diagnostic and Summary records; keep diagnostics and shift
      # its 0-based span coordinates to the unified 1-based schema.
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        select(.type == "Diagnostic" or (.type == null and .primary_label)) | {
          path: $path,
          line: (.primary_label.span.start_line + 1),
          col: (.primary_label.span.start_column + 1),
          end_line: (.primary_label.span.end_line + 1),
          end_col: (.primary_label.span.end_column + 1),
          severity: sev(.severity),
          code: .code,
          message: .message,
          source: "selene"
        }'
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  else
    selene ${args[@]+"${args[@]}"} "$file" || rc=$?
  fi

  return "$rc"
}

_lint_statix() {
  # Positional contract from _lint_dispatch: $1 file, $2 dir, $3 config_source,
  # $4 config_path. statix auto-discovers .statix.toml upward from the file.
  local file="$1" _dir="$2" _config_source="$3" _config_path="${4:-}" rc=0 out tool_rc
  command -v statix &>/dev/null || return 0

  if [ "$json" -eq 1 ]; then
    out=$(statix check --format json "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      # statix JSON is [{file, report: [{diagnostics: [{at: {from/to: {line, column}},
      # message, severity, code}]}]}]. Severity is title-cased ("Warn", "Error").
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        .[]? | .report[]? | .diagnostics[]? | {
          path: $path,
          line: .at.from.line,
          col: .at.from.column,
          end_line: .at.to.line,
          end_col: .at.to.column,
          severity: sev(.severity),
          code: (.code | tostring),
          message: .message,
          source: "statix"
        }'
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  elif [ "$fix" -eq 1 ]; then
    statix fix "$file" || rc=$?
  else
    statix check "$file" || rc=$?
  fi

  return "$rc"
}

_lint_buf() {
  # Positional contract from _lint_dispatch: $1 file, $2 dir, $3 config_source,
  # $4 config_path. buf auto-discovers buf.yaml from the file's directory tree.
  local file="$1" _dir="$2" _config_source="$3" _config_path="${4:-}" rc=0 out tool_rc
  command -v buf &>/dev/null || return 0

  if [ "$json" -eq 1 ]; then
    out=$(buf lint --error-format=json "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      # buf lint emits one JSON object per line; each has path, start_line,
      # start_column, end_line, end_column, type (rule id), message.
      printf '%s' "$out" | jq -c --arg path "$file" '
        select(.path? and .message?) | {
          path: $path,
          line: (.start_line // 1),
          col: (.start_column // 1),
          end_line: .end_line,
          end_col: .end_column,
          severity: "warning",
          code: .type,
          message: .message,
          source: "buf"
        }'
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  else
    buf lint "$file" || rc=$?
  fi

  return "$rc"
}
