#!/usr/bin/env bash
# helpers.sh — shared test framework for checkrun tests.
#
# Source this file from test scripts to get assertion helpers,
# temp directory management, and a summary reporter.
#
# Usage:
#   . "./test/helpers.sh"
#   _assert_eq "description" "expected" "actual"
#   ...
#   _test_summary  # prints results, exits 0 or 1

PASS=0
FAIL=0
CLEANUP_DIRS=()

# Mark every suite, including suites run directly, so code that can reach
# outside the mock HOME can avoid touching the real host during WSL tests.
export REPO_TEST=1

# The repo test runner may set TEST_STYLE=1 for child suites when styled output is
# appropriate. Individual suites keep exporting NO_COLOR for deterministic tool
# output, so this opt-in is separate from NO_COLOR and only affects our harness
# status lines.
_TEST_PRETTY=false
[[ "${TEST_STYLE:-0}" = 1 ]] && _TEST_PRETTY=true

_test_style() {
  local color="$1"
  shift
  if $_TEST_PRETTY; then
    local sgr
    case "$color" in
      green) sgr='38;2;63;185;80' ;;
      red) sgr='38;2;248;81;73' ;;
      yellow) sgr='38;2;210;153;34' ;;
      dim) sgr='38;2;139;148;158' ;;
      bold) sgr='1' ;;
      *) sgr='0' ;;
    esac
    printf '\033[%sm%s\033[0m\n' "$sgr" "$*"
  else
    echo "$*"
  fi
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

_pass() {
  PASS=$((PASS + 1))
  if $_TEST_PRETTY; then
    _test_style green "  ✓ $1"
  else
    echo "  PASS: $1"
  fi
}
_fail() {
  FAIL=$((FAIL + 1))
  if $_TEST_PRETTY; then
    _test_style red "  ✗ $1" >&2
  else
    echo "  FAIL: $1" >&2
  fi
}

_assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected '$expected', got '$actual')"
  fi
}

_assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected to contain '$expected', got '$actual')"
  fi
}

_canonical_test_path() {
  local path="$1" dir base absdir

  # macOS temp paths can be reported through either `/var/...` or the
  # canonical `/private/var/...` spelling depending on whether a shell helper,
  # Python pathlib, or the invoked tool touched the path. Tests care that the
  # same file was routed, not which spelling an OS layer chose.
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
    return
  fi

  case "$path" in
    */*)
      dir="${path%/*}"
      base="${path##*/}"
      [[ -n "$dir" ]] || dir=/
      ;;
    *)
      dir=.
      base="$path"
      ;;
  esac

  absdir=$(cd "$dir" && pwd -P) || return 1
  if [[ "$absdir" == "/" ]]; then
    printf '/%s\n' "$base"
  else
    printf '%s/%s\n' "$absdir" "$base"
  fi
}

_assert_contains_path_arg() {
  local desc="$1" prefix="$2" path="$3" actual="$4"
  local expected canonical

  expected="${prefix}${path}"
  canonical="${prefix}$(_canonical_test_path "$path")"

  if [[ "$actual" == *"$expected"* || "$actual" == *"$canonical"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected to contain '$expected' or '$canonical', got '$actual')"
  fi
}

_assert_contains_path_arg_suffix() {
  local desc="$1" prefix="$2" path="$3" suffix="$4" actual="$5"
  local expected canonical

  expected="${prefix}${path}${suffix}"
  canonical="${prefix}$(_canonical_test_path "$path")${suffix}"

  if [[ "$actual" == *"$expected"* || "$actual" == *"$canonical"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected to contain '$expected' or '$canonical', got '$actual')"
  fi
}

_assert_not_contains_path_arg() {
  local desc="$1" prefix="$2" path="$3" actual="$4"
  local unexpected canonical

  unexpected="${prefix}${path}"
  canonical="${prefix}$(_canonical_test_path "$path")"

  if [[ "$actual" != *"$unexpected"* && "$actual" != *"$canonical"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (should not contain '$unexpected' or '$canonical')"
  fi
}

_assert_not_contains() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "$actual" != *"$unexpected"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (should not contain '$unexpected')"
  fi
}

_assert_colon_list_values_aligned() {
  local desc="$1" content="$2" marker="$3"
  local in_list=0 expected_col="" row_count=0
  local line label after_colon spaces col

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$marker" ]]; then
      in_list=1
      continue
    fi

    [[ "$in_list" -eq 1 ]] || continue
    [[ -n "$line" ]] || break

    if [[ "$line" != "  "*:* ]]; then
      _fail "$desc (unexpected list row '$line')"
      return
    fi

    label=${line%%:*}
    after_colon=${line#*:}
    spaces=${after_colon%%[! ]*}

    if [[ -z "$spaces" || "$spaces" == "$after_colon" ]]; then
      _fail "$desc (missing list spacing after '$label:')"
      return
    fi

    col=$((${#label} + 1 + ${#spaces}))
    if [[ -z "$expected_col" ]]; then
      expected_col=$col
    elif [[ "$col" -ne "$expected_col" ]]; then
      _fail "$desc (list starts at column $col, expected $expected_col: '$line')"
      return
    fi

    row_count=$((row_count + 1))
  done <<<"$content"

  if [[ "$row_count" -eq 0 ]]; then
    _fail "$desc (no rows found after '$marker')"
  else
    _pass "$desc"
  fi
}

_assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" -eq "$actual" ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected exit $expected, got $actual)"
  fi
}

_assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    _pass "$desc"
  else
    _fail "$desc (file not found: $path)"
  fi
}

_assert_file_missing() {
  local desc="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    _pass "$desc"
  else
    _fail "$desc (file should not exist: $path)"
  fi
}

_assert_file_content() {
  local desc="$1" expected="$2" path="$3"
  if [[ -f "$path" ]]; then
    local actual
    actual=$(cat "$path")
    if [[ "$actual" == "$expected" ]]; then
      _pass "$desc"
    else
      _fail "$desc (expected content '$expected', got '$actual')"
    fi
  else
    _fail "$desc (file not found: $path)"
  fi
}

# ---------------------------------------------------------------------------
# Temp directory management
# ---------------------------------------------------------------------------

_TEST_TMP_ROOT=$(mktemp -d) || {
  echo "failed to create test temp root" >&2
  exit 1
}
if [[ -z "$_TEST_TMP_ROOT" || ! -d "$_TEST_TMP_ROOT" ]]; then
  echo "mktemp returned invalid test temp root: $_TEST_TMP_ROOT" >&2
  exit 1
fi
CLEANUP_DIRS+=("$_TEST_TMP_ROOT")

_tmpdir() {
  local d
  d=$(mktemp -d "$_TEST_TMP_ROOT/tmp.XXXXXX") || {
    echo "failed to create test temp directory" >&2
    exit 1
  }
  if [[ -z "$d" || "$d" != "$_TEST_TMP_ROOT"/* || ! -d "$d" ]]; then
    echo "mktemp returned invalid test temp directory: $d" >&2
    exit 1
  fi
  echo "$d"
}

_checkrun_default_config_dir() {
  local dir
  dir=$(_tmpdir)

  # These fixtures model checkrun's fallback contract without depending on a
  # developer's real host config when CI runs with HOME set to the checkout.
  cat >"$dir/shfmt.toml" <<'EOF'
indent = 2
switch_case_indent = true
EOF
  cat >"$dir/clang-format" <<'EOF'
---
AllowShortBlocksOnASingleLine: Never
AllowShortFunctionsOnASingleLine: Empty
IndentWidth: 2
PointerAlignment: Left
UseTab: Never
...
EOF
  cat >"$dir/ruff.toml" <<'EOF'
indent-width = 4
line-length = 100

[lint]
select = ["E", "F", "I", "UP", "B"]
EOF
  cat >"$dir/stylua.toml" <<'EOF'
indent_type = "Spaces"
indent_width = 2
column_width = 100
EOF
  cat >"$dir/rustfmt.toml" <<'EOF'
max_width = 100
tab_spaces = 4
hard_tabs = false
EOF
  cat >"$dir/taplo.toml" <<'EOF'
[formatting]
align_entries = false
indent_string = "  "
reorder_keys = false
trailing_newline = true
EOF
  cat >"$dir/biome.json" <<'EOF'
{
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100,
    "lineEnding": "lf"
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "double"
    }
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true
    }
  }
}
EOF
  cat >"$dir/shellcheckrc" <<'EOF'
disable=SC1091
EOF
  cat >"$dir/selene.toml" <<'EOF'
[rules]
unused_variable = "warn"
bad_string_escape = "allow"
EOF
  cat >"$dir/rumdl.toml" <<'EOF'
[global]
disable = ["MD013", "MD033", "MD038", "MD042"]
EOF
  cat >"$dir/hadolint.yaml" <<'EOF'
{}
EOF
  cat >"$dir/checkmake.ini" <<'EOF'
[minphony]
disabled = true
EOF
  cat >"$dir/typos.toml" <<'EOF'
[default]
extend-ignore-re = []
EOF

  printf '%s\n' "$dir"
}

_cleanup() {
  for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do
    rm -rf "$d"
  done
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Common test setup
# ---------------------------------------------------------------------------

# Create a mock HOME, saving the original. Sets TEST_HOME, REAL_HOME, HOME.
_mock_home() {
  # shellcheck disable=SC2034  # REAL_HOME is used by callers
  REAL_HOME="$HOME"
  TEST_HOME=$(_tmpdir)
  export HOME="$TEST_HOME"
  # Isolate tests from the real global git config (e.g. core.fsmonitor
  # would spawn daemons watching temp work-trees and hang).  Use an
  # empty file, not /dev/null, so git config --global writes succeed.
  export GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig-test"
  touch "$GIT_CONFIG_GLOBAL"
}

# Create a temp bin directory for mock commands. Returns the path.
# IMPORTANT: callers must also run `export PATH="$dir:$PATH"` since
# $() runs in a subshell and the export here won't affect the caller.
_mock_bin() {
  local d
  d=$(_tmpdir)
  echo "$d"
}

_mock_checkrun_infra_bin() {
  local d tool found

  d=$(_mock_bin)
  for tool in bash dirname mktemp python3 rm yq; do
    found=$(command -v "$tool") || {
      echo "required test infrastructure tool not found: $tool" >&2
      exit 1
    }
    ln -s "$found" "$d/$tool"
  done
  echo "$d"
}

# ---------------------------------------------------------------------------
# Portable timeout wrapper — `timeout` is GNU coreutils and is absent on
# macOS by default. Falls back to `gtimeout` (installed by `brew install
# coreutils`), and to running the command directly if neither is present
# (CI's outer job timeout will still catch a hang).
# ---------------------------------------------------------------------------

_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Platform checks
# ---------------------------------------------------------------------------

# Check if prebuilt tool binaries will work on this platform. macOS
# ships native binaries; the concern is musl-based Linux (Alpine)
# where glibc-linked binaries fail.
_has_compatible_libc() {
  [[ "$(uname -s)" != "Linux" ]] && return 0
  # Do not use `grep -q` here: with pipefail enabled, grep can exit early
  # after a match and make verbose `ldd` implementations fail with SIGPIPE.
  ldd --version 2>&1 | grep -iE 'glibc|gnu libc' >/dev/null 2>&1
}
# Skip the entire test suite only on Linux libc variants that cannot run the
# prebuilt tools used by these fixtures. macOS remains in coverage.
_require_compatible_libc() {
  if ! _has_compatible_libc; then
    echo "SKIP: $1 (requires glibc-compatible Linux libc)"
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

_test_summary() {
  echo ""
  if $_TEST_PRETTY; then
    local summary_color=green
    [[ $FAIL -ne 0 ]] && summary_color=red
    _test_style "$summary_color" "────────────────────────────────"
    if [[ $FAIL -eq 0 ]]; then
      _test_style green "✓ Results: $PASS passed, $FAIL failed"
    else
      _test_style red "✗ Results: $PASS passed, $FAIL failed"
    fi
    _test_style "$summary_color" "────────────────────────────────"
  else
    echo "================================"
    echo "Results: $PASS passed, $FAIL failed"
    echo "================================"
  fi
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
}
