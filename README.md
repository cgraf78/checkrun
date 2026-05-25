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
checkrun capabilities --json
checkrun explain [--json] FILE [FILE...]
checkrun format FILE [FILE...]
checkrun lint [--fix] [--json] FILE [FILE...]
autoformat FILE [FILE...]
autolint [--fix] [--json] FILE [FILE...]
```

`autoformat` always mutates eligible files. It exits 0 even when a formatter
fails so save-time hooks surface stderr without blocking the caller.

`autolint` is read-only by default, applies fixes with `--fix`, and emits
newline-delimited diagnostics with `--json`. It exits non-zero when lint
findings exist.

Both commands ignore missing, deleted, or explicitly ignored files. Missing
language tools are treated as graceful no-ops so a host without a language
toolchain does not break unrelated workflows.

`checkrun capabilities --json` emits machine-readable filetype metadata for
editor integrations. `checkrun explain` reports the normalized
path, inferred filetype, phase-specific ignore decisions, candidate
formatter/linter tools, fallback config names, and matching schema associations
for selected files.

## Dependencies

- Bash for the CLI entry points and shell libraries.
- `yq` is required by `autoformat` and by `autolint` once at least one lintable
  file remains after filtering.
- `jq` is required by `autolint --json`, schema association policy, and any
  checks that need JSON diagnostics.
- `python3` is required for schema association helpers.
- `shdeps` is required only when a schema association policy references a
  dependency-owned schema with `"dependency": "owner/repo"`.

Formatter and linter backends such as `ruff`, `shfmt`, `shellcheck`, `stylua`,
`biome`, and `rumdl` are optional. Missing backends are graceful no-ops for
their file types so hosts can install only the language tools they use.

CI installs a representative backend set from
`.github/mise/checkrun-ci.toml` before running the full test suite. That file
is test infrastructure for this repo; installed consumers should provide their
own toolchain through the host environment or integration layer.

## Public API

- `bin/checkrun`, `bin/autoformat`, and `bin/autolint` are the PATH-visible
  CLIs.
- `share/checkrun/registry.json` is the shared tooling registry. It drives
  filetype inference, formatter/linter selection, `checkrun plan`,
  `checkrun explain`, and the derived `checkrun capabilities --json` output.
- `share/checkrun/schemas/registry.schema.json` validates the registry shape;
  `lib/checkrun/registry.py` enforces cross-object invariants that JSON Schema
  cannot express cleanly.
- `lib/checkrun/schemas/schema_policy.py` is the schema association API shared
  by editors and linting. Associations may set `"dependency": "owner/repo"` and
  a repo-relative `"schema"` path when a schema is public API owned by a
  shdeps-managed dependency; the interpreter resolves those through
  `shdeps dep-file`.
- `lib/checkrun/schemas/schema-lint.py` validates files through that policy.
- `share/checkrun/schemas/associations.schema.json` is the JSON Schema for
  schema association policy files.
- `share/checkrun/shell.sh` is a stable no-op shell loader for integration
  harnesses that source each dependency's shell API uniformly.

Source non-binary assets through shdeps so install locations stay under the
dependency manager's contract:

```bash
. "$(shdeps dep-file cgraf78/checkrun share/checkrun/shell.sh)"
python3 "$(shdeps dep-file cgraf78/checkrun lib/checkrun/schemas/schema_policy.py)" --nvim
checkrun capabilities --json
```

## Editor And Hook Flow

Editors, agent hooks, Git hooks, or Sapling hooks can either call `autoformat`
and `autolint` directly or route through a higher-level policy tool such as
Sley. Sley's default hook policy delegates back to these CLIs, while consumers
can override that layer for repo-specific policy.

The important contract is one-way: `checkrun` owns formatter/linter dispatch,
and consumers decide when to invoke it.

## Configs

Global fallback configs live under `~/.config/autoformat` by default. Set
`CHECKRUN_AUTOFORMAT_DIR` or `CHECKRUN_AUTOLINT_DIR` to override the config
root for a run. The single config root is intentional: several backends,
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
2. Add a selector for the normalized filetype, then add a step with the tool
   name, adapter id, and config policy when the tool has Checkrun-owned config
   discovery. Use step-level `pathPatterns` only to narrow a tool within an
   already inferred filetype.
3. Add the adapter id under `adapters` and implement the named shell function.
4. Dispatch that adapter id from `autoformat.sh` or `autolint.sh`.
5. Add registry-plan coverage plus adapter behavior tests.

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
| Go | `goimports` + `gofumpt` | `golangci-lint` |
| Lua | `stylua` | `selene` |
| C/C++ | `clang-format` | - |
| CMake | `cmake-format` | `cmake-lint` |
| Rust | `rustfmt` | `cargo clippy` |
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

Basename-only files such as `Dockerfile`, `BUCK`, `BUILD`, `TARGETS`,
`WORKSPACE`, `MODULE.bazel`, and `Containerfile` are dispatched before
extension-based handling. Extensionless shell scripts are detected by shebang
or dotfile name.

The shared shell library provides config walking helpers, shell classification,
batched TOML key reads, nested-key config walks, and ignore-file matching for
both `autoformat` and `autolint`.

## License

MIT. See [`LICENSE`](LICENSE).
