# shellcheck shell=bash
# shellcheck disable=SC2154
# Programming-language lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `fix`/`json`
# flags instead of maintaining their own global option state.

_lint_ruby() {
  local file="$1" dir="$2" cfg args=()
  command -v rubocop &>/dev/null || return 0

  cfg=$(_find_rubocop_config "$dir" "$CHECKRUN_AUTOLINT_DIR" 2>/dev/null || true)
  [ -n "$cfg" ] && args=(--config "$cfg")
  if [ "$fix" -eq 1 ]; then
    _lint_text_command "rubocop" "$file" rubocop --autocorrect \
      "${args[@]}" "$file"
  else
    _lint_text_command "rubocop" "$file" rubocop "${args[@]}" "$file"
  fi
}

_php_cli() {
  local candidate

  # Managed hosts can put a non-PHP compatibility shim ahead of PHP on PATH.
  # Probe every candidate so project/user PHP still wins when deliberately first.
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    "$candidate" -v 2>&1 | grep -q 'HipHop VM' && continue
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
    echo "$candidate"
    return 0
  done

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

_lint_rust() {
  local file="$1" dir="$2" manifest manifest_dir
  command -v cargo &>/dev/null || return 0

  manifest=$(_find_config "$dir" Cargo.toml 2>/dev/null || true)
  [ -n "$manifest" ] || return 0
  cargo clippy --version &>/dev/null || return 0
  manifest_dir="${manifest%/*}"

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

  if [ "$fix" -eq 1 ]; then
    cargo clippy --fix --allow-dirty --allow-staged \
      --manifest-path "$manifest" --all-targets -- -D warnings
  else
    cargo clippy --manifest-path "$manifest" --all-targets -- -D warnings
  fi
}

_lint_go() {
  local file="$1" dir="$2" rc=0 out tool_rc gc_dir gc_base
  local args=()
  local has_gc_config=0

  command -v golangci-lint &>/dev/null || return 0
  if _has_config "$dir" ".golangci.yml" ||
    _has_config "$dir" ".golangci.yaml" ||
    _has_config "$dir" ".golangci.toml" ||
    _has_config "$dir" ".golangci.json"; then
    has_gc_config=1
  fi
  if [ "$has_gc_config" -eq 0 ] &&
    [ -f "$CHECKRUN_AUTOLINT_DIR/golangci-lint.yml" ]; then
    args=(--config "$CHECKRUN_AUTOLINT_DIR/golangci-lint.yml")
  fi

  # golangci-lint expects package paths, not single files. Run from the file's
  # directory on ./... and filter JSON results back to this file.
  gc_dir=$(dirname "$file")
  gc_base=$(basename "$file")
  if [ "$json" -eq 1 ]; then
    out=$(cd "$gc_dir" && golangci-lint run --output-format=json "${args[@]}" ./... 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" --arg base "$gc_base" "$_JQ_SEVLIB"'
        .Issues[]? | select(.Pos.Filename | endswith($base)) | {
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
    (cd "$gc_dir" && golangci-lint run --fix "${args[@]}" ./...) || rc=$?
  else
    (cd "$gc_dir" && golangci-lint run "${args[@]}" ./...) || rc=$?
  fi

  return "$rc"
}

_lint_ruff() {
  local file="$1" dir="$2" rc=0 out tool_rc
  local args=()
  local has_ruff_config=0

  command -v ruff &>/dev/null || return 0
  # pyproject.toml[tool.ruff] counts as repo policy so ruff's own resolution is
  # not silently replaced by the personal fallback.
  if _has_config "$dir" "ruff.toml" ||
    _has_config "$dir" ".ruff.toml" ||
    _walk_config_with_key "$dir" pyproject.toml toml \
      '.tool.ruff // .tool.ruff.lint'; then
    has_ruff_config=1
  fi
  if [ "$has_ruff_config" -eq 0 ] &&
    [ -f "$CHECKRUN_AUTOLINT_DIR/ruff.toml" ]; then
    args=(--config "$CHECKRUN_AUTOLINT_DIR/ruff.toml")
  fi

  if [ "$json" -eq 1 ]; then
    out=$(ruff check --output-format=json-lines "${args[@]}" "$file" 2>/dev/null)
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
    ruff check --fix "${args[@]}" "$file" || rc=$?
  else
    ruff check "${args[@]}" "$file" || rc=$?
  fi

  return "$rc"
}

_lint_selene() {
  local file="$1" dir="$2" rc=0 selene_cfg out tool_rc
  local args=()

  command -v selene &>/dev/null || return 0
  # selene discovery is cwd-sensitive, so pass the selected config explicitly.
  selene_cfg=$(_find_config "$dir" "selene.toml" 2>/dev/null ||
    _find_config "$dir" ".selene.toml" 2>/dev/null || true)
  if [ -n "$selene_cfg" ]; then
    args=(--config "$selene_cfg")
  elif [ -f "$CHECKRUN_AUTOLINT_DIR/selene.toml" ]; then
    args=(--config "$CHECKRUN_AUTOLINT_DIR/selene.toml")
  fi

  if [ "$json" -eq 1 ]; then
    out=$(selene --display-style=json2 "${args[@]}" "$file" 2>/dev/null)
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
    selene "${args[@]}" "$file" || rc=$?
  fi

  return "$rc"
}
