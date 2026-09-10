# shellcheck shell=bash
# shellcheck disable=SC2154
# Shell-family lint adapters.
#
# Adapter helpers read the current invocation's dynamically scoped `json` flag.

# Fallback shellcheckrc path already warned about this process. The
# translator below only maps `disable=` to `-e`; anything else is reported
# once per process for the active fallback path (single-slot record, so
# switching paths re-warns) rather than once per linted file.
_CHECKRUN_SHELLCHECK_FALLBACK_WARNED=""

_shellcheck_lang_hint() {
  case "${1##*/}" in
    .bashrc | .bash_profile | .profile | .envrc | envrc | envrc-*)
      printf 'bash\n'
      ;;
  esac
}

_lint_sh() {
  local file="$1" lang="${3:-}" config_source="${4:-}" config_path="${5:-}"
  local args=()
  command -v shellcheck &>/dev/null || return 0
  [ -n "$lang" ] && args+=(-s "$lang")

  # Apply the global shellcheckrc by translating its directives to CLI flags.
  # ShellCheck 0.9.0 (common on older Ubuntu/WSL) does not support --rcfile, and
  # ShellCheck does not discover this XDG-style fallback path itself.
  #
  # Project `.shellcheckrc` is still left to ShellCheck's native discovery, but
  # the decision to suppress the fallback comes from the registry plan. That
  # keeps `checkrun plan`, explain output, and execution on the same policy path.
  #
  # Only `disable=` is translatable (`-e`); any other directive is reported
  # instead of silently dropped so fallback authors learn it did not apply.
  if [ "$config_source" = "fallback" ] && [ -f "$config_path" ]; then
    local key val line unsupported=" "
    while IFS= read -r line || [ -n "$line" ]; do
      # Tolerate CRLF files, surrounding whitespace, and trailing comments so
      # an innocent `disable=SC2086 # reason` does not become a garbage `-e`
      # value (shellcheck rejects it with `Invalid number`, rc 3). Keys and
      # disable values never contain `#`, so comment stripping is safe here.
      line=${line%$'\r'}
      line=${line%%#*}
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      [ -n "$line" ] || continue
      case "$line" in
        *=*)
          key=${line%%=*}
          val=${line#*=}
          ;;
        *)
          key="$line"
          val=""
          ;;
      esac
      # Allow `key = value` spacing around the separator.
      key=${key%"${key##*[![:space:]]}"}
      val=${val#"${val%%[![:space:]]*}"}
      val=${val%"${val##*[![:space:]]}"}
      # An empty key is malformed input; report the raw line, not nothing.
      [ -n "$key" ] || key="$line"
      case "$key" in
        disable) [ -n "$val" ] && args+=(-e "$val") ;;
        *)
          # Deduplicate so one warning line names each ignored directive once.
          case "$unsupported" in
            *" $key "*) ;;
            *) unsupported="$unsupported$key " ;;
          esac
          ;;
      esac
    done <"$config_path"
    if [ "$unsupported" != " " ] &&
      [ "$_CHECKRUN_SHELLCHECK_FALLBACK_WARNED" != "$config_path" ]; then
      printf 'checkrun: warning: %s: only %s is translated; ignoring:%s\n' \
        "$config_path" "'disable='" "${unsupported% }" >&2
      _CHECKRUN_SHELLCHECK_FALLBACK_WARNED="$config_path"
    fi
  fi
  if [ "$json" -eq 1 ]; then
    local out tool_rc
    out=$(shellcheck -f json1 ${args[@]+"${args[@]}"} "$file" 2>/dev/null)
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
  shellcheck ${args[@]+"${args[@]}"} "$file"
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
