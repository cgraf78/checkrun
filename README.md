# checkrun

![Tests](https://github.com/cgraf78/checkrun/actions/workflows/test.yml/badge.svg?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/bash-%3E%3D3.2-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-lightgrey.svg)](#)

`checkrun` owns formatter, linter, and file-check dispatch used by the
`checkrun`, `autoformat`, and `autolint` CLIs. Other tools can depend on those
CLIs as their formatting and linting policy surface.

## CLIs

```text
checkrun registry --json
checkrun capabilities --json
checkrun explain [--json] FILE [FILE...]
checkrun plan --json [--phase format|lint] FILE [FILE...]
checkrun verify [--json] [--tool cargo-audit|cargo-clippy|clang-tidy|golangci-lint|govulncheck] [PATH...]
checkrun format FILE [FILE...]
checkrun lint|check [--fix] [--json] FILE [FILE...]
autoformat FILE [FILE...]
autolint [--fix] [--json] FILE [FILE...]
```

`autoformat` always mutates eligible files. It exits 0 even when a formatter
fails so save-time hooks surface stderr without blocking the caller.

`autolint` is read-only by default, applies fixes with `--fix`, and emits
newline-delimited diagnostics with `--json`. It exits non-zero when lint
findings exist. `checkrun lint` and `checkrun check` are aliases for this same
fast linter path.

`checkrun verify` is the explicit project-check surface for work that should
not run from save-time editor lint. Its project backends are deduplicated by
owner root: Go analyzers run once per `go.mod`, Rust analyzers run once per
`Cargo.toml`, and C/C++ `clang-tidy` runs for selected C/C++ files only when
project metadata makes the invocation meaningful. Missing path arguments are
still treated as scope hints for verify, so deleted or renamed Go/Rust/C++
files can trigger checks for the nearest surviving owning project context.

The formatter and linter entry points ignore missing, deleted, or explicitly
ignored files. Missing language tools are treated as graceful no-ops so a host
without a language toolchain does not break unrelated workflows.

`checkrun registry --json` emits the raw registry for debugging and tests.
`checkrun capabilities --json` emits machine-readable filetype and editor
language-ID metadata for editor integrations. `checkrun plan --json` emits the
stable execution-plan API for integrations that need to inspect Checkrun
decisions without running tools.
`checkrun explain` reports the normalized path, inferred filetype,
phase-specific ignore decisions, candidate formatter/linter tools, fallback
config names, and matching schema associations for selected files.

See [`docs/workflow-contract.md`](docs/workflow-contract.md) for the
cross-surface ownership contract between Checkrun, Sley, editor adapters,
dotfiles, humans, and agents.

## Dependencies

- Bash for the CLI entry points and shell libraries.
- `yq` is required by `autoformat` and by `autolint` once at least one lintable
  file remains after filtering.
- `jq` is required by `autolint --json`, schema association policy, and any
  checks that need JSON diagnostics.
- Python 3.11+ is required for registry planning and schema association helpers.
  Set `CHECKRUN_PYTHON` to a compatible interpreter when the host default
  `python3` does not include stdlib `tomllib`.
- `shdeps` is required only when a schema association policy references a
  dependency-owned schema with `"dependency": "owner/repo"`.

Formatter, linter, and verification backends such as `ruff`, `shfmt`,
`shellcheck`, `stylua`, `biome`, `rumdl`, `cargo-audit`, and `govulncheck` are
optional. Missing backends are graceful no-ops for their file types or project
roots so hosts can install only the language tools they use.

CI installs a representative backend set from
`.github/mise/checkrun-ci.toml` before running the full test suite. That file
is test infrastructure for this repo; installed consumers should provide their
own toolchain through the host environment or integration layer.

## Public API

- `bin/checkrun`, `bin/autoformat`, and `bin/autolint` are the PATH-visible
  CLIs.
- `share/checkrun/registry.json` is the shared tooling registry. It drives
  filetype inference, formatter/linter selection, `checkrun plan`,
  `checkrun explain`, editor language-ID aliases, and the derived
  `checkrun capabilities --json` output.
- `share/checkrun/schemas/registry.schema.json` validates the registry shape;
  the internal `lib/checkrun/registry.py` interpreter enforces cross-object
  invariants that JSON Schema cannot express cleanly.
- `lib/checkrun/schemas/schema_policy.py` is the public schema association API
  shared by editors and linting. `--lsp-schemas` emits the editor/LSP
  projection. Its documented Python facade is limited to the module's `__all__`;
  other helpers are internal. Associations may set `"dependency": "owner/repo"`
  and a repo-relative `"schema"` path when a schema is public API owned by a
  shdeps-managed dependency; the interpreter resolves those through
  `shdeps dep-file`. Associations may set `editorSource` when an editor-native
  schema URI should be exposed to LSP/editor clients without making it a
  refreshable or offline-enforced schema source.
- `lib/checkrun/nvim.lua` is the optional Neovim adapter API. It does not
  depend on shdeps, Sley, LazyVim, Mason, or local editor policy; callers pass
  explicit commands, environment, and working directories when they do not want
  the PATH/default-script behavior.
- `lib/checkrun/schemas/schema-lint.py` validates files through that policy.
- `lib/checkrun/schemas/schema_refresh.py` refreshes pinned public schema
  payloads from association `source` URLs. It is exposed as
  `checkrun schema refresh` so host repos can run the same updater directly or
  from scheduled CI.
- `lib/checkrun/verify.py` runs explicit project-scope verification checks.
  These checks are intentionally separate from registry lint capabilities so
  editor integrations do not inherit slow, broad, or network-sensitive scans.
- `share/checkrun/schemas/associations.schema.json` is the JSON Schema for
  schema association policy files.
- `share/checkrun/schemas/diagnostics.schema.json` is the JSON Schema for one
  newline-delimited diagnostic emitted by `autolint --json`. Editor adapters use
  this producer-owned contract when translating Checkrun diagnostics into their
  native diagnostic APIs.
- `share/checkrun/shell.sh` is a stable no-op shell loader for integration
  harnesses that source each dependency's shell API uniformly.

Source non-binary assets through shdeps so install locations stay under the
dependency manager's contract:

```bash
. "$(shdeps dep-file cgraf78/checkrun share/checkrun/shell.sh)"
python3 "$(shdeps dep-file cgraf78/checkrun lib/checkrun/schemas/schema_policy.py)" --lsp-schemas
checkrun capabilities --json
```

### Neovim Adapter API

The Neovim module is a protocol adapter, not a complete plugin. It translates
Checkrun's public capability and schema-policy outputs into Neovim data
structures while leaving routing policy in the consuming config.

```lua
local checkrun_nvim = dofile("lib/checkrun/nvim.lua")

vim.filetype.add(checkrun_nvim.filetypes({
  command = { "checkrun", "capabilities", "--json" },
}))

local yaml_before_init = checkrun_nvim.yaml_before_init({
  command = { "python3", "lib/checkrun/schemas/schema_policy.py", "--lsp-schemas" },
})
```

Public functions:

- `capabilities(opts)` reads and normalizes `checkrun capabilities --json`.
- `filetypes(opts)` converts Checkrun custom filetype metadata into
  `vim.filetype.add` input.
- `add_filetypes(opts)` registers those filetypes and returns the registered
  table.
- `json_schemas(opts)`, `yaml_schemas(opts)`, and
  `toml_schema_associations(opts)` return the corresponding LSP schema maps.
- `yaml_before_init(opts)` returns a yamlls `before_init` callback that merges
  Checkrun's YAML schema policy with SchemaStore when SchemaStore is installed.

Supported options are `command`, `env`, `cwd`, direct `capabilities` or
`config` tables for tests/pre-fetched callers, and `script`/`python` for the
default schema-policy command. The module does not choose formatter/linter
plugin names, Treesitter parsers, LSP servers, package managers, keymaps, or
workspace roots.

## Editor And Hook Flow

Editors, agent hooks, Git hooks, or Sapling hooks can either call `autoformat`
and `autolint` directly or route through a higher-level policy tool such as
Sley. Sley's default hook policy delegates back to these CLIs, while consumers
can override that layer for repo-specific policy.

The important contract is one-way: `checkrun` owns formatter/linter dispatch,
and consumers decide when to invoke it. Sley and editor adapters should consume
Checkrun's public CLIs and JSON APIs instead of carrying their own language
maps, selector tables, or direct low-level tool dispatch.

## Fast Check Policy

`checkrun check`, `checkrun lint`, and `autolint` are the fast automatic check
surface for editors, hooks, and agents. A backend belongs there only when it is
safe to run from changed-file or save-time workflows:

- it is bounded to the selected file, or to a small owner project that the
  adapter can discover cheaply from that file
- it does not require network access, dependency installation, vulnerability
  database updates, full test suites, or broad repository scans
- it produces deterministic diagnostics or fixes without hidden repository
  mutations
- missing tool binaries remain graceful no-ops
- project-contextual tools are gated by explicit metadata when running them on
  standalone files would be noisy, slow, or conceptually wrong

The current automatic lint surface includes schema validation, spelling, and the
supported file/path-scoped tools in the table below. That includes Python
`ruff`, GitHub Actions `actionlint` and `zizmor`, and other registry-selected
linters. Broader analyzers such as dependency vulnerability scanners, package
audits, full type-check suites, and repository health commands belong in
`checkrun verify` or in Sley's verify registry unless they can satisfy the same
fast-check contract.

The registry encodes that policy with adapter `executionScope` metadata.
Automatic lint selectors may only use file-scoped adapters; broader generic
analyzers live behind `checkrun verify`, which accepts files or directories and
chooses the owning project checks itself. This keeps Sley, editor adapters, and
hooks from needing their own Go/Rust/C++ tool-selection tables.

## Configs

Global fallback configs live under `~/.config/checkrun` by default. Set
`CHECKRUN_CONFIG_DIR` to override the config root for a run. The single config
root is intentional: several backends,
including Ruff, Biome, Rubocop, Rumdl, and Taplo, use one policy file for both
formatting and linting.

Ignore policy can be phase-specific. `ignore` remains the backward-compatible
all-phase skip. Use `format-ignore` to skip formatting only, `lint-ignore` to
skip every lint phase, `spell-ignore` to skip only `typos`, `schema-ignore` to
skip only schema validation, and `tool-ignore` to skip only the language- or
filetype-specific backend linter. This lets vendored config data avoid
formatting or spelling churn while still receiving structural validation.

Schema association policy defaults to `~/.config/checkrun/associations.json`.
Set `CHECKRUN_SCHEMA_ASSOCIATIONS` to point at a different policy file for a
single run, test fixture, or integration harness. Local schema payload names
resolve under `.local/share/checkrun/schemas` by default; a policy can override
that with `schemaDataDir`.

Normal schema validation never fetches association `source` URLs. `schema-lint`
uses local schema payloads through `schema_policy.schema_path()` so hooks and CI
remain deterministic offline. Editors can still prefer public `source` URLs
or editor-native `editorSource` URLs through the `--lsp-schemas` projection.

Refresh pinned public schema payloads explicitly:

```bash
checkrun schema refresh
checkrun schema refresh --check
checkrun schema refresh --association "Ruff fallback config"
```

The refresh command selects associations that declare `source` and do not
declare `dependency`; dependency-owned schemas are refreshed by their owning
repos. Fetched payloads must be valid JSON, and when `jsonschema` is available
they must also validate as JSON Schemas before replacing the pinned file.
Writes are atomic and use a canonical generated JSON layout so future diffs are
stable. `--check` reports drift without writing and is intended for scheduled
CI in host repos that track schema payloads.

## Implementation Layout

- `common.sh` owns shared path normalization and shell helpers that adapters
  still need at execution time.
- `autoformat.sh` owns formatter CLI behavior and adapter-id dispatch.
- `autolint.sh` owns linter CLI behavior, diagnostic normalization, linter
  adapter-id dispatch, and read-only batching.
- `linters/*.sh` owns the linter backend adapters grouped by domain:
  `shell`, `web`, `build`, `config`, `languages`, `docs`, and
  `github-actions`.

`shdeps` installs each executable in `bin/` as a PATH-visible symlink, so these
entry points resolve their dependency libraries without relying on consumer
wrapper scripts.

To add a formatter or linter, update the registry first:

1. Add or reuse filetype inference under `filetypes`.
2. If an editor uses a different language ID for that normalized filetype, add
   the alias under `editorLanguageIds`. Keep editor-specific naming there so
   VS Code, Neovim, hooks, and CLI planning share one Checkrun vocabulary
   instead of carrying separate translation tables.
3. Add a selector for the normalized filetype, then add a step with the tool
   name, adapter id, and config policy when the tool has Checkrun-owned config
   discovery. Use step-level `pathPatterns` only on selector steps to narrow a
   tool within an already inferred filetype. Use `requiresConfigMatch` for
   tools that should run only when their config policy finds project metadata.
4. Confirm lint steps satisfy the fast-check policy above, and mark their
   adapter with `executionScope: "file"` when they do. If the tool is
   project-wide, network-sensitive, or expected to be slow, add it under
   `checkrun verify` or a Sley verify registry instead of the automatic lint
   surface.
5. Add the adapter id under `adapters` and implement the named shell function.
6. Dispatch that adapter id from `autoformat.sh` or `autolint.sh`.
7. Add registry-plan coverage plus adapter behavior tests.

Do not add a second filename or extension decision table in selectors or shell.
The top-level `filetypes` table answers what the file is; selectors answer which
tools apply to that normalized filetype; shell adapters only answer how to invoke
that tool. Adapter helpers should return 0 when the underlying tool is missing,
keep formatter failures advisory where appropriate, and preserve `autolint`'s
dynamically scoped `fix` and `json` behavior.

## Supported Tools

| File type | Formatter | Linter |
| --- | --- | --- |
| Python | `ruff format` | `ruff check` |
| Shell | `shfmt` | `shellcheck` |
| Zsh | `shfmt` | `zsh -n` |
| Go | `goimports` + `gofumpt` | - |
| Lua | `stylua` | `selene` |
| C/C++ | `clang-format` | gated `clang-tidy` |
| CMake | `cmake-format` | `cmake-lint` |
| Rust | `rustfmt` | - |
| Java | `google-java-format` | dry-run format check |
| PHP | `php-cs-fixer` | `php -l` |
| Ruby | `rubocop` layout autocorrect | `rubocop` |
| HTML | `superhtml fmt` | `superhtml check` |
| TOML | `taplo` | `taplo` |
| JSON/JSONC/CSS/JS/JSX/TS/TSX | `biome` | `biome` |
| YAML | `yamlfmt` | - |
| GitHub Actions | `yamlfmt` | `actionlint` + `zizmor` |
| Markdown | `rumdl` | `rumdl` |
| Spelling | - | `typos` |
| Starlark | `buildifier` | `buildifier --lint` |
| Make | - | `checkmake` |
| Dockerfile/Containerfile | `dockerfmt` | `hadolint` |
| EditorConfig | - | `editorconfig-checker` |
| Git config | - | `git config --file --list` |
| Crontab | - | `crontab -T` |
| Tmux config | - | `tmux source-file -n` |
| Systemd units | - | `systemd-analyze verify` |

`clang-tidy` is intentionally gated: it runs only when the target file's parent
chain contains `.clang-tidy`, `compile_commands.json`, or `compile_flags.txt`.
That keeps save-time editor lint quiet for standalone C/C++ files while still
using project-owned rule and compile metadata when it exists.

Broad project analyzers are intentionally not listed as file linters. Run them
explicitly with `checkrun verify [PATH...]` or `--tool` filters:

- `golangci-lint` walks to `go.mod` roots and runs `golangci-lint run ./...`
  once per module.
- `govulncheck` walks to `go.mod` roots and runs `govulncheck ./...` once per
  module.
- `cargo clippy` walks to Rust project roots that have `Cargo.toml`, then runs
  `cargo clippy --all-targets` once per project.
- `cargo-audit` walks to Rust project roots that have both `Cargo.toml` and
  `Cargo.lock`, then runs `cargo audit` once per project. The lockfile gate is
  intentional: dependency-audit results belong to locked project state, not
  standalone Rust source files.
- Verify-time `clang-tidy` walks selected C/C++ files and directories while
  preserving the same `.clang-tidy`, `compile_commands.json`, or
  `compile_flags.txt` metadata gate as fast lint.
- Deleted or renamed file paths are still useful verify scope hints: Go/Rust
  paths select their nearest surviving module or project, while deleted C/C++
  files select the nearest surviving directory context.

Missing verification tools are no-ops, matching the rest of Checkrun's optional
backend policy.

Basename-only files such as `Dockerfile`, `BUCK`, `BUILD`, `TARGETS`,
`WORKSPACE`, `MODULE.bazel`, and `Containerfile` are dispatched before
extension-based handling. Extensionless shell scripts are detected by shebang
or dotfile name.

The shared shell library provides config walking helpers, shell classification,
batched TOML key reads, nested-key config walks, and ignore-file matching for
both `autoformat` and `autolint`.

## License

MIT. See [`LICENSE`](LICENSE).
