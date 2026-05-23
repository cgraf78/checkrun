# shellcheck shell=bash
# shellcheck disable=SC2154
# Shell-family lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `json` flag.

_shellcheck_lang_hint() {
  case "${1##*/}" in
    .bashrc | .bash_profile | .profile | .envrc | envrc | envrc-*)
      printf 'bash\n'
      ;;
  esac
}

_lint_sh() {
  local file="$1" dir="$2" lang="${3:-}"
  local args=()
  command -v shellcheck &>/dev/null || return 0
  [ -n "$lang" ] && args+=(-s "$lang")
  # Apply the global shellcheckrc by translating its directives to CLI flags.
  # ShellCheck 0.9.0 (common on older Ubuntu/WSL) does not support --rcfile, and
  # ShellCheck does not discover this XDG-style fallback path itself.
  if ! _has_config "$dir" ".shellcheckrc" &&
    [ -f "$CHECKRUN_AUTOLINT_DIR/shellcheckrc" ]; then
    local key val
    while IFS='=' read -r key val; do
      case "$key" in
        disable) args+=(-e "$val") ;;
      esac
    done < <(grep -E '^[a-z-]+=' "$CHECKRUN_AUTOLINT_DIR/shellcheckrc")
  fi
  if [ "$json" -eq 1 ]; then
    local out tool_rc
    out=$(shellcheck -f json1 "${args[@]}" "$file" 2>/dev/null)
    tool_rc=$?
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq -c --arg path "$file" "$_JQ_SEVLIB"'
        .comments[]? | {
          path: $path,
          line: .line,
          col: .column,
          end_line: .endLine,
          end_col: .endColumn,
          severity: sev(.level),
          code: ("SC" + (.code|tostring)),
          message: .message,
          source: "shellcheck"
        }'
    fi
    return "$tool_rc"
  fi
  shellcheck "${args[@]}" "$file"
}

_lint_zsh() {
  command -v zsh &>/dev/null || return 0
  if [ "$json" -eq 1 ]; then
    local err tool_rc
    err=$(zsh -n "$1" 2>&1 1>/dev/null)
    tool_rc=$?
    if [ "$tool_rc" -ne 0 ]; then
      # `zsh -n` prints `file:LINE: message`. Preserve the line when possible,
      # but keep JSON mode parseable if the format changes.
      local line msg
      if [[ $err =~ :([0-9]+):\ (.*)$ ]]; then
        line="${BASH_REMATCH[1]}"
        msg="${BASH_REMATCH[2]}"
      else
        line=1
        msg="$err"
      fi
      jq -cn --arg p "$1" --arg m "$msg" --argjson l "$line" '{
        path: $p, line: $l, col: 1, severity: "error",
        message: $m, source: "zsh"
      }'
    fi
    return "$tool_rc"
  fi
  zsh -n "$1"
}
