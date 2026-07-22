#!/usr/bin/env bash
# autoformat implementation — auto-format files by extension.
# Requires yq, which should be installed by the host bootstrap path.
# No-ops gracefully if a formatter is not installed.
# Respects per-repo config files; uses Checkrun's XDG config root when absent.
#
# Usage: autoformat [-h|--help] <file> [file...]

set -u

# shellcheck source=common.sh
CHECKRUN_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$CHECKRUN_LIB_DIR" == "${BASH_SOURCE[0]}" ]] && CHECKRUN_LIB_DIR=.
. "$CHECKRUN_LIB_DIR/common.sh"

_autoformat_usage() {
  printf '%s\n' \
    "Usage: autoformat [-h|--help] <file> [file...]" \
    "" \
    "Auto-format files by extension. Unsupported files, missing files, ignored" \
    "files, and files whose formatter is not installed are skipped." \
    "" \
    "Supported file types:" \
    "  Build:     .bzl, BUCK, BUILD, CMakeLists.txt, .cmake" \
    "  C/C++:     .c, .cc, .cpp, .cxx, .h, .hpp, .hxx" \
    "  Config:    .toml, .yaml, .yml" \
    "  Container: Dockerfile, Containerfile" \
    "  Docs/text: .md" \
    "  Go:        .go" \
    "  Java:      .java" \
    "  Lua:       .lua" \
    "  Nix:       .nix" \
    "  PHP:       .php" \
    "  Protobuf:  .proto" \
    "  Python:    .py" \
    "  Ruby:      .rb" \
    "  Rust:      .rs" \
    "  Shell:     .sh, .bash, .zsh, extensionless files with a shell shebang, .bashrc, .zshrc, .profile, .envrc" \
    "  Web/data:  .css, .scss, .less, .js, .jsx, .ts, .tsx, .json, .jsonc, .html, .htm" \
    "" \
    "Options:" \
    "  -h, --help  Show this help and exit."
}

# Run a formatter, buffering stderr so successful runs stay silent.
# Several formatters chat on stderr even on success (prettier emits
# "path 12ms", clang-format and shfmt occasionally warn on benign
# input); that noise drowns out the edit-hook output on every save.
# If the formatter fails we surface the buffered stderr so real
# problems still land in the user's console.
_run_fmt() {
  local err rc
  # If mktemp fails (full disk, read-only $TMPDIR) we still want the
  # formatter to run — just skip the stderr buffering and let the
  # caller see whatever chatter the tool produces. Worse UX but still
  # correct output.
  if ! err=$(mktemp 2>/dev/null); then
    "$@"
    return $?
  fi
  "$@" 2>"$err"
  rc=$?
  # `cat` on an empty file is harmless and one fewer stat per invocation than
  # gating with `[ -s ]`. On real tool errors there's almost always something
  # in the stderr buffer; on empty buffers cat is a no-op.
  [ "$rc" -ne 0 ] && cat "$err" >&2
  rm -f "$err"
  return "$rc"
}

# Dispatch sh/bash/zsh through a single shfmt invocation. Exists
# purely to dedupe the three extension branches plus the extensionless
# shebang path; `lang` is the `-ln` value ("" for default bash parsing,
# "zsh" for zsh scripts).
_format_sh() {
  local file="$1" dir="$2" lang="${3:-}" config_source="${4:-}" config_path="${5:-}"
  local args=() v_indent="" v_sci=""
  command -v shfmt &>/dev/null || return 0

  [ -n "$lang" ] && args+=("-ln=$lang")

  # shfmt reads EditorConfig on its own. Only translate the fallback
  # TOML into CLI flags when the repo has no .editorconfig, otherwise
  # the explicit flags would override the repo's local style.
  if [ "$config_source" = "fallback" ] && [ -f "$config_path" ]; then
    {
      read -r v_indent
      read -r v_sci
    } < <(
      _toml_read_keys "$config_path" indent switch_case_indent
    )
    [ -n "$v_indent" ] && args+=(-i "$v_indent")
    [ "$v_sci" = "true" ] && args+=(-ci)
  fi

  _run_fmt shfmt ${args[@]+"${args[@]}"} -w "$file"
}

_format_cmake() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v cmake-format &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config-files "$config_path")
  _run_fmt cmake-format -i ${args[@]+"${args[@]}"} "$file"
}

_format_ruby() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v rubocop &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config "$config_path")
  # Limit autoformat to RuboCop's Layout department. Full RuboCop
  # autocorrect can rewrite code semantics; layout-only keeps save-time
  # formatting predictable while autolint handles broader diagnostics.
  _run_fmt rubocop --autocorrect --only Layout --format quiet \
    ${args[@]+"${args[@]}"} "$file"
}

_format_php() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v php-cs-fixer &>/dev/null || return 0

  [ -n "$config_path" ] && args=(--config "$config_path")
  _run_fmt php-cs-fixer fix --quiet --using-cache=no ${args[@]+"${args[@]}"} "$file"
}

_format_java() {
  # Positional contract from _format_dispatch is (file, dir, config_source,
  # config_path). google-java-format has no per-dir or config knob, so the rest
  # are named-ignored to keep the dispatch contract visible at the call site.
  local file="$1" _dir="${2:-}" _config_source="${3:-}" _config_path="${4:-}"
  command -v google-java-format &>/dev/null || return 0
  _run_fmt google-java-format -i "$file"
}

_format_ruff() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v ruff &>/dev/null || return 0

  # The registry already decided whether project policy or fallback policy
  # applies. Only force Ruff's config for the fallback case: project-local
  # pyproject/ruff.toml discovery is Ruff's native behavior and keeps relative
  # config includes interpreted the way Ruff expects.
  [ "$config_source" = "fallback" ] && [ -n "$config_path" ] && args=(--config "$config_path")
  _run_fmt ruff format --quiet ${args[@]+"${args[@]}"} "$file"
  # Also sort imports (`I` rule) as a format-adjacent fix. The full lint rule
  # set runs via autolint --fix; scoping here to imports-only keeps
  # autoformat-on-save deterministic and avoids broad lint rewrites.
  _run_fmt ruff check --quiet --fix --select=I ${args[@]+"${args[@]}"} "$file"
}

_format_goimports() {
  # Positional contract from _format_dispatch is (file, dir, config_source,
  # config_path). goimports has no config knob — the rest are named-ignored so
  # the dispatch contract stays readable.
  local file="$1" _dir="${2:-}" _config_source="${3:-}" _config_path="${4:-}"
  command -v goimports &>/dev/null || return 0
  _run_fmt goimports -w "$file"
}

_format_gofumpt() {
  # Same positional contract as _format_goimports — gofumpt has no project-aware
  # knobs, so dir / config_source / config_path are named-ignored.
  local file="$1" _dir="${2:-}" _config_source="${3:-}" _config_path="${4:-}"
  command -v gofumpt &>/dev/null || return 0
  _run_fmt gofumpt -w "$file"
}

_format_sh_zsh() {
  _format_sh "$1" "$2" "zsh" "${3:-}" "${4:-}"
}

_format_clang() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v clang-format &>/dev/null || return 0

  # clang-format walks for project `.clang-format` files by itself, but it does
  # not know about the personal fallback file. The registry tells us when the
  # fallback is the selected policy, and only that case needs an explicit style.
  if [ "$config_source" = "fallback" ] && [ -n "$config_path" ]; then
    args=(-style="file:$config_path")
  fi
  _run_fmt clang-format -i ${args[@]+"${args[@]}"} "$file"
}

_format_stylua() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v stylua &>/dev/null || return 0

  # stylua treats stylua.toml and .editorconfig as project style sources. Pass
  # only the fallback explicitly so project policy remains native and local.
  if [ "$config_source" = "fallback" ] && [ -n "$config_path" ]; then
    args=(--config-path "$config_path")
  fi
  _run_fmt stylua ${args[@]+"${args[@]}"} "$file"
}

_format_rustfmt() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}"
  local args=() cargo_edition
  command -v rustfmt &>/dev/null || return 0

  # Cargo owns parser edition, while rustfmt.toml owns style. Keeping edition
  # inference in the adapter avoids turning the registry into a project model.
  cargo_edition=$(_find_cargo_edition "$dir" 2>/dev/null || true)
  [ -n "$cargo_edition" ] && args+=(--edition "$cargo_edition")
  if [ "$config_source" = "fallback" ] && [ -n "$config_path" ]; then
    args+=(--config-path "$config_path")
  fi
  _run_fmt rustfmt ${args[@]+"${args[@]}"} "$file"
}

_format_taplo() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v taplo &>/dev/null || return 0

  # taplo's config discovery starts from process cwd, so both project and
  # fallback selections from the registry are passed explicitly.
  [ -n "$config_path" ] && args=(--config "$config_path")
  _run_fmt taplo fmt ${args[@]+"${args[@]}"} "$file"
}

_format_biome() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v biome &>/dev/null || return 0

  # Biome accepts a config root directory, not the config file. The registry's
  # self-config guard returns `native` for the config file itself so we avoid
  # handing Biome the same root twice and triggering nested-root errors.
  if [ "$config_source" != "native" ] && [ -n "$config_path" ]; then
    args=(--config-path "$(dirname "$config_path")")
  fi
  # `biome check --write --linter-enabled=false` runs formatter + assist
  # (organize imports etc.) but skips lint fixes. Autolint owns lint fixes so
  # save-time formatting never applies broader behavior-changing rewrites.
  _run_fmt biome check --write --linter-enabled=false \
    ${args[@]+"${args[@]}"} "$file"
}

_format_superhtml() {
  # Positional contract from _format_dispatch is (file, dir, config_source,
  # config_path). superhtml has no config knob — the rest are named-ignored so
  # the dispatch contract is visible.
  local file="$1" _dir="${2:-}" _config_source="${3:-}" _config_path="${4:-}"
  command -v superhtml &>/dev/null || return 0
  _run_fmt superhtml fmt "$file"
}

_format_buildifier() {
  # Same positional contract — buildifier has no per-dir/config knob.
  local file="$1" _dir="${2:-}" _config_source="${3:-}" _config_path="${4:-}"
  command -v buildifier &>/dev/null || return 0
  _run_fmt buildifier "$file"
}

_format_dockerfmt() {
  # Same positional contract — dockerfmt has no per-dir/config knob.
  local file="$1" _dir="${2:-}" _config_source="${3:-}" _config_path="${4:-}"
  command -v dockerfmt &>/dev/null || return 0
  _run_fmt dockerfmt -w "$file"
}

_format_nixfmt() {
  # Same positional contract — nixfmt has no config knob; it formats in place.
  local file="$1" _dir="${2:-}" _config_source="${3:-}" _config_path="${4:-}"
  command -v nixfmt &>/dev/null || return 0
  _run_fmt nixfmt "$file"
}

_format_buf() {
  # Same positional contract — buf discovers buf.yaml from the file's directory
  # tree automatically; no explicit config path is needed.
  local file="$1" _dir="${2:-}" _config_source="${3:-}" _config_path="${4:-}"
  command -v buf &>/dev/null || return 0
  _run_fmt buf format -w "$file"
}

_format_yamlfmt() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v yamlfmt &>/dev/null || return 0

  # yamlfmt does not walk upward from the target file. The registry walk gives
  # us a cwd-independent config path, so pass project and fallback policies.
  [ -n "$config_path" ] && args=(-conf "$config_path")
  _run_fmt yamlfmt ${args[@]+"${args[@]}"} "$file"
}

_format_rumdl() {
  local file="$1" dir="$2" config_source="${3:-}" config_path="${4:-}" args=()
  command -v rumdl &>/dev/null || return 0

  # rumdl --fix doubles as a formatter: it auto-fixes markdown rule violations
  # without becoming a prose reflower. Keep project config native but point at
  # the fallback when the registry selected personal policy.
  if [ "$config_source" = "fallback" ] && [ -n "$config_path" ]; then
    args=(--config "$config_path")
  fi
  _run_fmt rumdl check --fix ${args[@]+"${args[@]}"} "$file"
}

_format_dispatch() {
  local adapter="$1" file="$2" filetype="$3" config_source="$4" config_path="$5"
  local dir
  dir=$(dirname "$file")

  # Adapter ids are the stable boundary between the registry and shell. This
  # case statement intentionally dispatches by adapter id only; filetype,
  # extension, basename, path-scope, and ignore decisions have already happened
  # inside the registry interpreter.
  case "$adapter" in
    biome-format) _format_biome "$file" "$dir" "$config_source" "$config_path" ;;
    buf-format) _format_buf "$file" "$dir" "$config_source" "$config_path" ;;
    buildifier-format) _format_buildifier "$file" "$dir" "$config_source" "$config_path" ;;
    clang-format) _format_clang "$file" "$dir" "$config_source" "$config_path" ;;
    cmake-format) _format_cmake "$file" "$dir" "$config_source" "$config_path" ;;
    dockerfmt) _format_dockerfmt "$file" "$dir" "$config_source" "$config_path" ;;
    gofumpt) _format_gofumpt "$file" "$dir" "$config_source" "$config_path" ;;
    goimports) _format_goimports "$file" "$dir" "$config_source" "$config_path" ;;
    google-java-format) _format_java "$file" "$dir" "$config_source" "$config_path" ;;
    nixfmt) _format_nixfmt "$file" "$dir" "$config_source" "$config_path" ;;
    php-cs-fixer) _format_php "$file" "$dir" "$config_source" "$config_path" ;;
    rubocop-format) _format_ruby "$file" "$dir" "$config_source" "$config_path" ;;
    ruff-format) _format_ruff "$file" "$dir" "$config_source" "$config_path" ;;
    rumdl-format) _format_rumdl "$file" "$dir" "$config_source" "$config_path" ;;
    rustfmt) _format_rustfmt "$file" "$dir" "$config_source" "$config_path" ;;
    shfmt) _format_sh "$file" "$dir" "" "$config_source" "$config_path" ;;
    shfmt-zsh) _format_sh_zsh "$file" "$dir" "$config_source" "$config_path" ;;
    stylua) _format_stylua "$file" "$dir" "$config_source" "$config_path" ;;
    superhtml-format) _format_superhtml "$file" "$dir" "$config_source" "$config_path" ;;
    taplo-format) _format_taplo "$file" "$dir" "$config_source" "$config_path" ;;
    yamlfmt) _format_yamlfmt "$file" "$dir" "$config_source" "$config_path" ;;
    *)
      echo "autoformat: unknown formatter adapter: $adapter" >&2
      return 125
      ;;
  esac
}

_format_one_with_plan() {
  # Dispatch a pre-built plan file. Split out of _format_one so the parent
  # process can pre-plan many files in a single Python call (see
  # _autoformat_pre_plan). The source file path is carried inside each plan
  # record, so this helper only needs the plan location.
  #
  # An empty plan file means "no formatter steps" (unsupported / ignored) —
  # return cleanly so missing-tool hosts can still save-on-edit those files.
  local plan_file="$1"
  local path filetype _phase adapter config_source config_path dispatch_rc

  [ -s "$plan_file" ] || return 0

  while IFS= read -r -d '' path &&
    IFS= read -r -d '' filetype &&
    IFS= read -r -d '' _phase &&
    IFS= read -r -d '' adapter &&
    IFS= read -r -d '' config_source &&
    IFS= read -r -d '' config_path; do
    # Formatter failures are advisory by design: `_run_fmt` surfaces useful
    # stderr, and the save hook continues with exit 0. Unknown adapter ids are
    # different from backend failures: they mean Checkrun's registry and shell
    # boundary drifted. Use a private sentinel instead of 127 so a missing
    # backend command cannot be mistaken for a broken registry.
    _format_dispatch "$adapter" "$path" "$filetype" "$config_source" "$config_path"
    dispatch_rc=$?
    if [ "$dispatch_rc" -eq 125 ]; then
      break
    fi
  done <"$plan_file"

  [ "${dispatch_rc:-0}" -eq 125 ] && return "$dispatch_rc"
  return 0
}

_format_one() {
  # Plan one file inline (one Python invocation per call) and dispatch. Used
  # when _autoformat_pre_plan is unavailable (mktemp/tmpdir broken) or as the
  # explicit single-file API. The batched path in _autoformat_main shares the
  # same _format_one_with_plan dispatch loop after pre-planning all files at
  # once.
  local file="$1" plan_file rc

  [ -z "$file" ] && return 0

  # Planning is the one place where filename, extension, shebang, path scope,
  # ignore files, and config-policy discovery are allowed to interact. Keeping
  # that work out of shell dispatch prevents the old metadata-vs-execution
  # drift from returning in a second table.
  plan_file=$(_checkrun_tempfile) || {
    echo "autoformat: could not create registry plan temp file" >&2
    return 1
  }
  _checkrun_registry shell-plan --phase format -- "$file" >"$plan_file"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _checkrun_remove "$plan_file"
    return "$rc"
  fi

  _format_one_with_plan "$plan_file"
  rc=$?
  _checkrun_remove "$plan_file"
  return "$rc"
}

_autoformat_pre_plan() {
  # Plan many files in a single Python invocation. Writes `<index>.plan` per
  # input file into a fresh dir whose path is echoed on stdout for the caller
  # to capture. Returns non-zero (and removes the dir) if the planner itself
  # fails — empty per-file plans are legitimate skips, not failures.
  local out_dir
  out_dir=$(mktemp -d "${TMPDIR:-/tmp}/autoformat-plans.XXXXXX") || return 1
  if ! _checkrun_registry shell-plan --output-dir "$out_dir" --phase format -- "$@"; then
    rm -rf "$out_dir"
    return 1
  fi
  printf '%s\n' "$out_dir"
}

_autoformat_main() {
  local arg file rc=0

  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        _autoformat_usage
        return 0
        ;;
    esac
  done

  # Zero file args is a successful no-op — exit before checking yq so a host
  # missing Python or yq doesn't error on commands that wouldn't have run anything
  # anyway (e.g. `autoformat $(get-changed-files)` with an empty result).
  [ "$#" -eq 0 ] && return 0

  _checkrun_resolve_config_dir CHECKRUN_CONFIG_DIR || return

  # Export so the Python planner subprocess sees the shell-resolved absolute
  # path without resolving it a second time after a backend changes cwd.
  export CHECKRUN_CONFIG_DIR

  if ! command -v yq >/dev/null 2>&1; then
    echo "autoformat: yq is required" >&2
    return 1
  fi

  # Pre-plan all files in one Python invocation, then dispatch each file from
  # its pre-built plan. Sequential dispatch is intentional: several formatters
  # (clang-format, biome, rustfmt) operate on shared project caches and racing
  # them on the same files corrupts the cache. The win here is only on the
  # planner cost — N python startups become one — which dominates save-hook
  # latency for any file count above ~5. If pre-planning fails (broken tmpdir,
  # registry corruption), fall back to per-file planning so we still produce
  # the same diagnostic flow. We can pass "$@" directly because any -h/--help
  # arg would have returned above before reaching this point.
  local plan_dir=""
  plan_dir=$(_autoformat_pre_plan "$@") || plan_dir=""
  if [ -n "$plan_dir" ]; then
    local idx=0
    for file in "$@"; do
      _format_one_with_plan "$plan_dir/$idx.plan" || rc=$?
      idx=$((idx + 1))
    done
    rm -rf "$plan_dir"
  else
    for file in "$@"; do
      _format_one "$file" || rc=$?
    done
  fi

  return "$rc"
}
