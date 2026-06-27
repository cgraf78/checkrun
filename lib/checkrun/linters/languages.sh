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
  # clang-tidy needs them on different CLI flags.
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

  [ -n "$clang_config$compile_root" ] || return 0
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

_lint_rust() {
  local file="$1" dir="$2" manifest manifest_dir
  command -v cargo &>/dev/null || return 0

  manifest=$(_find_config "$dir" Cargo.toml 2>/dev/null || true)
  [ -n "$manifest" ] || return 0
  cargo clippy --version &>/dev/null || return 0
  manifest_dir="${manifest%/*}"

  # JSON mode (editor/unified-diagnostics) is correctness-critical: nvim-lint
  # needs every file's diagnostics. With the manifest-scoped dedup that the
  # non-JSON path uses below, losing subshells return 0 immediately while the
  # winner filters clippy's workspace-wide output down to its own single file —
  # so diagnostics for sibling .rs files in the same Cargo workspace would be
  # silently dropped. Skip the dedup in JSON mode and let every subshell run
  # clippy. Cargo's per-workspace target-dir lock serializes the concurrent
  # invocations (extra "Blocking waiting for file lock" lines on stderr, which
  # we discard with 2>/dev/null); the first cold compile pays the full cost,
  # subsequent invocations reuse the cache. Slower wall-clock vs the single-
  # winner approach, but each file's diagnostics survive into the JSON stream.
  if [ "$json" -eq 1 ]; then
    local out tool_rc
    out=$(cargo clippy --message-format=json --manifest-path "$manifest" \
      --all-targets -- -D warnings 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c \
        --arg path "$file" \
        --arg manifest_dir "$manifest_dir" \
        "$_JQ_SEVLIB"'
        select(.reason == "compiler-message")
        | .message as $msg
        | ($msg.spans // [] | map(select(.is_primary == true)) | .[0]) as $span
        | select($span)
        | select(($manifest_dir + "/" + $span.file_name) == $path or $span.file_name == $path)
        | {
          path: $path,
          line: $span.line_start,
          col: $span.column_start,
          end_line: $span.line_end,
          end_col: $span.column_end,
          severity: sev($msg.level),
          code: $msg.code.code,
          message: $msg.message,
          source: "clippy"
        }'
    fi
    return "$tool_rc"
  fi

  # Non-JSON mode: clippy prints the same workspace-wide report on every
  # invocation. Deduplicate with an atomic mkdir sentinel keyed on the
  # manifest: the first subshell to win creates it and runs clippy; the rest
  # return 0 immediately. $$ is the parent autolint PID — shared across all
  # co-batch subshells, distinct between invocations.
  local sentinel sentinel_hash
  sentinel_hash=$(printf '%s' "$manifest" | cksum | cut -d' ' -f1)
  sentinel="${TMPDIR:-/tmp}/autolint-rust-$$-${sentinel_hash}"
  if ! mkdir "$sentinel" 2>/dev/null; then
    return 0
  fi
  # No cleanup trap: the sentinel must outlive this subshell so that other
  # co-batch subshells (which may start after this one finishes) still see it
  # and skip. $$ is the parent autolint PID — unique per invocation — so the
  # sentinel is naturally scoped to one autolint run and won't block future
  # runs. /tmp is cleared by the OS; the directories are empty and tiny.

  if [ "$fix" -eq 1 ]; then
    cargo clippy --fix --allow-dirty --allow-staged \
      --manifest-path "$manifest" --all-targets -- -D warnings
  else
    cargo clippy --manifest-path "$manifest" --all-targets -- -D warnings
  fi
}

_lint_go() {
  # Positional contract from _lint_dispatch: $1 file, $2 dir, $3 config_source,
  # $4 config_path. golangci-lint reads its config from --config regardless of
  # source, so dir and config_source are named-ignored.
  local file="$1" _dir="$2" _config_source="$3" config_path="${4:-}"
  local rc=0 out tool_rc gc_dir
  local args=()

  command -v golangci-lint &>/dev/null || return 0
  [ -n "$config_path" ] && args=(--config "$config_path")

  # golangci-lint expects package paths, not single files. Run from the file's
  # directory on ./... and filter JSON results back to this file.
  gc_dir=$(dirname "$file")
  if [ "$json" -eq 1 ]; then
    out=$(cd "$gc_dir" && golangci-lint run --output-format=json ${args[@]+"${args[@]}"} ./... 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      # Compare canonical paths, not basenames. The previous `endswith($base)`
      # filter false-positived on any file whose name ended with the same
      # string — e.g. `xmain.go` matched `main.go` — and also misattributed
      # issues from same-basename files in sub-packages reached by ./...
      # `.Pos.Filename` from golangci-lint is relative to the run directory
      # (gc_dir), so a clean join gives the absolute path to compare against
      # the absolute `$file` already normalized by _lintable_path.
      printf '%s' "$out" | jq -c --arg path "$file" --arg dir "$gc_dir" "$_JQ_SEVLIB"'
        .Issues[]?
        | (.Pos.Filename | sub("^\\./"; "")) as $rel
        | select(($dir + "/" + $rel) == $path or .Pos.Filename == $path)
        | {
          path: $path,
          line: .Pos.Line,
          col: .Pos.Column,
          severity: sev(.Severity),
          code: .FromLinter,
          message: .Text,
          source: "golangci-lint"
        }'
    fi
    [ "$tool_rc" -ne 0 ] && rc=$tool_rc
  elif [ "$fix" -eq 1 ]; then
    (cd "$gc_dir" && golangci-lint run --fix ${args[@]+"${args[@]}"} ./...) || rc=$?
  else
    (cd "$gc_dir" && golangci-lint run ${args[@]+"${args[@]}"} ./...) || rc=$?
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
