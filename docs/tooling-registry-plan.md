# Checkrun Tooling Registry Refactor Plan

## Goal

Refactor Checkrun so one registry drives both metadata and execution behavior.
The final state should make it impossible for `checkrun explain`, editor
capabilities, `autoformat`, and `autolint` to drift because they disagree about
which tools apply to a file.

## Scope

In scope:

- add a versioned Checkrun tooling registry
- add a JSON Schema for the registry
- add a registry interpreter
- derive capabilities from the registry
- move `checkrun explain` to the registry interpreter
- add a testable execution-plan API
- refactor `autoformat` and `autolint` to execute registry-selected adapters
- update dotfiles Neovim integration to consume generic capabilities
- document ownership boundaries

Out of scope:

- moving tool config files out of dotfiles
- changing Sley verify registry behavior
- changing Sley changed-file scope behavior
- adding user-level tool preferences
- replacing shell adapters with Python adapters
- publishing a package artifact beyond the existing shdeps repo layout

## Design Principles

1. Registry selects; adapters execute.

   The registry should answer "what applies to this file?" Shell adapters should
   answer "how does this specific tool need to be invoked?"

2. Derived outputs are not sources of truth.

   `checkrun capabilities --json` and `checkrun explain` should be projections
   from the registry, not hand-maintained metadata.

3. No downstream names in Checkrun.

   Checkrun should expose generic integration concepts. It should not contain a
   `sley`, `nvim`, or dotfiles-specific key.

4. Config content stays outside Checkrun.

   Checkrun can know that `ruff.toml` is the fallback config name. It should not
   own the contents of that config.

5. Prefer a clean cutover over compatibility shims.

   This is currently a single-user toolchain. Do not carry legacy `sley`
   capability output or maintain parallel registry files just for backwards
   compatibility. Preserve intentional workflow behavior, but migrate consumers
   directly to the new contract.

6. Keep the registry small.

   The registry is a selection model, not a command DSL. Avoid adding preference
   engines, generated shell, or generic command-argument encoding until the
   existing toolchain has a concrete need for them.

## Migration Sequence

### Commit 1: Add registry schema and seed registry

Files:

- `share/checkrun/registry.json`
- `share/checkrun/schemas/registry.schema.json`
- `test/suites/registry-test`
- `test/checkrun-test`

Work:

- model the intended current behavior in `registry.json`
- resolve existing drift before seeding the registry; metadata-only tools are
  invalid unless shell dispatch and tests implement the same behavior
- include filetype maps now hard-coded in `explain.py`
- include adapter ids for every current tool
- include config-policy names and fallback file names
- validate `registry.json` against `registry.schema.json`
- fail tests if downstream-specific keys such as `sley` appear

Validation:

- `test/checkrun-test`
- direct schema validation in `registry-test`
- fixture tests proving the seeded registry matches current intended
  autoformat/autolint behavior for every documented filetype
- invalid fixture tests for unknown fields, duplicate selector ids, missing
  adapters, missing config policies, invalid phases, unsupported preference
  fields, and downstream-specific keys
- invalid runtime registry tests proving Checkrun commands fail loudly instead of
  silently treating all files as unsupported

### Commit 2: Add registry interpreter

Files:

- `lib/checkrun/registry.py`
- `test/suites/registry-test`

Work:

- load registry
- validate required registry invariants
- infer filetype by filename, extension, pattern, and shebang
- match selectors by normalized filetype and apply step-level path patterns
- derive generic capabilities
- expose a focused test helper for registry fixtures

Validation:

- representative filetype inference tests
- generic YAML vs GitHub workflow YAML tests
- Dockerfile, CMakeLists, Makefile, systemd, shell dotfile, and agent-hook tests
- extensionless shell tests for `.profile`, `.envrc`, `envrc-*`, shebang bash,
  shebang zsh, unknown text, and binary files
- path-pattern tests for absolute paths, cwd-relative paths, and basename-only
  matching
- unknown-file tests proving no formatter/linter steps are selected
- duplicate-selector tests proving exact duplicate steps run once, while
  non-identical overlapping steps remain visible in declaration order
- tests proving registry planning does not access the network

### Commit 3: Move capabilities output to registry

Files:

- `bin/checkrun`
- `lib/checkrun/explain.py` or a new CLI wrapper
- `test/suites/checkrun-cli-test`
- `test/suites/capabilities-test`

Work:

- make `checkrun capabilities --json` emit derived generic capabilities
- add `checkrun registry --json` for raw registry inspection
- remove the physical `capabilities.json` data source

Validation:

- capabilities JSON contains generic `filetypes.format`, `filetypes.lint`, and
  `filetypes.custom`
- capabilities JSON has no downstream-specific consumer key
- capabilities output is sorted and stable
- capabilities output is derived from registry fixtures, not a separate
  hand-written metadata file

Commits 3 and 4 are a coordinated local cutover across Checkrun and dotfiles.
Because the old downstream-specific capabilities shape is intentionally not
preserved, do not push either repo until both sides have been updated and tested.

### Commit 4: Update dotfiles Neovim consumer

Files in dotfiles:

- `.config/nvim/lua/config/language-policy.lua`
- Neovim/dotfiles tests that cover this module
- `.config/nvim` docs when public local behavior changes

Work:

- read generic Checkrun capabilities
- map `filetypes.format` to local formatter plugin name `sley`
- map `filetypes.lint` to local linter plugin name `sley`
- map `filetypes.custom` into `vim.filetype.add`
- keep CLI fallback through `checkrun capabilities --json`
- remove dependence on `capabilities.sley`

Validation:

- dotfiles test suite
- Neovim policy unit test for generic capabilities
- JSON fixture test for malformed, empty, and valid capabilities payloads
- shdeps-path load and CLI fallback paths both work
- empty/malformed Checkrun capabilities degrade to empty maps without breaking
  Neovim startup

### Commit 5: Remove downstream-specific capabilities shape

Files:

- Checkrun registry/capabilities code
- Checkrun tests
- README/docs

Work:

- delete `share/checkrun/capabilities.json` after Checkrun emits derived generic
  capabilities
- remove any remaining legacy `sley` output from tests and docs
- update README public API docs

Validation:

- `rg "capabilities\\.sley|\"sley\"" share/checkrun lib/checkrun test`
  should find no Checkrun metadata ownership leaks, except tests that explicitly
  assert absence

### Commit 6: Add execution plan API

Files:

- `bin/checkrun`
- `lib/checkrun/registry.py`
- `test/suites/checkrun-cli-test`
- `test/suites/registry-test`

Work:

- add `checkrun plan --json`
- support `--phase format` and `--phase lint`
- include ignore decisions, selected steps, skipped steps, and resolved configs
- ensure `explain` and `plan` use the same internal planner

Validation:

- golden plan fixtures for core filetypes
- test that `explain` selected tools match `plan` selected tools
- test phase ignore behavior for `format-ignore`, `lint-ignore`,
  `spell-ignore`, `schema-ignore`, and `tool-ignore`
- test all-phase `ignore` suppresses every phase
- test missing files and unsupported files produce empty plans without errors
- test `--` separator and filenames beginning with `-`
- test plan generation does not execute formatter/linter binaries
- test omitted `--phase` returns all phases, while `--phase format` and
  `--phase lint` return only requested phase data
- test deterministic cross-cutting-before-tool ordering
- test invalid registry, missing registry, and malformed registry errors are
  clear and non-zero
- test schema association reporting still comes from the schema association
  policy, not from the tooling registry

### Commit 7: Refactor autoformat dispatch

Files:

- `lib/checkrun/autoformat.sh`
- tests under `test/suites/autoformat-test`

Work:

- replace top-level filename/extension dispatch with plan consumption
- introduce adapter dispatch by adapter id
- keep existing tool-specific formatter functions and behavior
- pass resolved config metadata to adapters where useful
- preserve missing-tool no-op behavior
- preserve formatter failure behavior

Validation:

- all existing autoformat tests
- added test that a registry-only selector controls dispatch
- added drift test that autoformat does not contain a parallel extension table
- formatter failure still exits 0 and surfaces buffered stderr only on failure
- missing formatter still exits 0
- formatter commands receive resolved config metadata correctly
- filenames beginning with `-` work through `--`
- symlinked `autoformat` and `checkrun format` entry points still resolve
  libraries correctly

### Commit 8: Refactor autolint dispatch

Files:

- `lib/checkrun/autolint.sh`
- `lib/checkrun/linters/*.sh`
- tests under `test/suites/autolint-test`

Work:

- replace top-level filename/extension dispatch with plan consumption
- preserve cross-cutting spell/schema/tool phase ordering
- keep current read-only batching behavior
- keep `--fix` sequential behavior
- keep JSON diagnostic behavior
- keep missing-tool no-op behavior

Validation:

- all existing autolint tests
- added tests for spell/schema/tool phase plans
- added test that generic YAML formats but does not lint as GitHub Actions
- added drift test that autolint does not contain a parallel extension table
- read-only lint batching remains bounded and deterministic enough for tests
- `--fix` remains sequential
- `--json` emits parseable newline-delimited diagnostics
- missing `jq` still errors only when `--json` is requested for lintable files
- missing `yq` behavior is intentionally specified and tested
- missing linter binaries remain no-ops
- phase-specific ignores can suppress spell/schema/tool independently

### Commit 9: Move generic config resolution into registry plans

Files:

- `lib/checkrun/registry.py`
- `lib/checkrun/common.sh`
- formatter/linter adapters
- tests

Work:

- move config discovery that is purely policy into `registry.py`
- keep shell helpers for operations still needed by adapters
- leave highly tool-specific command flag shaping in adapters
- ensure plan explains whether config came from project, fallback, native, or
  none

Validation:

- config fallback tests for Ruff, Biome, Taplo, Rumdl, Rustfmt, CMake,
  RuboCop, Hadolint, GolangCI-Lint, Selene, and yamlfmt
- tests for relative `CHECKRUN_CONFIG_DIR`
- project-local config wins over fallback config
- fallback config is used only when the fallback file exists
- config roots are absolutized before adapter execution
- Biome self-config guard still avoids nested root configuration errors
- Rust edition discovery from Cargo manifests still affects rustfmt formatting
- parser-backed config detection, such as `pyproject.toml` with `[tool.ruff]`,
  still suppresses fallback config

### Commit 10: Documentation and cleanup

Files:

- `README.md`
- `docs/tooling-registry-spec.md`
- `docs/tooling-registry-plan.md`
- dotfiles README files when dotfiles behavior or documented setup changes

Work:

- update public API docs
- document registry ownership boundaries
- document how to add a tool
- document how dotfiles should add fallback config files
- remove stale references to `capabilities.json`

Validation:

- `git diff --check`
- repo test suite
- dotfiles test suite if dotfiles docs/config changed
- Sley test suite if Sley docs/config changed

## Test Matrix

Checkrun tests should cover:

- registry schema validation
- registry invariants
- runtime behavior for missing, malformed, and invariant-invalid registries
- filetype inference
- selector matching
- duplicate selector deduplication and ordering
- path pattern matching
- derived capabilities
- explain/plan consistency
- formatter dispatch via plan
- linter dispatch via plan
- config resolution
- phase-specific ignores
- missing tools as no-ops
- JSON diagnostics
- CLI contract coverage for `checkrun format`, `checkrun lint`, `autoformat`,
  and `autolint`
- symlinked executable resolution
- macOS/Linux CI coverage for the current supported shell runtime
- WSL path/cwd behavior where existing CI covers it
- missing/deleted file behavior
- unsupported file behavior
- path arguments beginning with `-`
- formatter failure exit behavior
- autolint finding/error exit behavior
- read-only lint concurrency and fix-mode sequencing
- schema association integration
- no network access during registry interpretation or plan generation

Minimum golden-file matrix:

| Case | Expected format | Expected lint |
| --- | --- | --- |
| `app.py` | `ruff-format` | `typos`, `schema-lint`, `ruff-lint` |
| `main.go` | `goimports`, `gofumpt` | `typos`, `schema-lint`, `golangci-lint` |
| `script.sh` | `shfmt` | `typos`, `schema-lint`, `shellcheck` |
| `.zshrc` | `shfmt` with zsh mode | `typos`, `schema-lint`, `zsh -n` |
| `Dockerfile` | `dockerfmt` | `typos`, `schema-lint`, `hadolint` |
| `CMakeLists.txt` | `cmake-format` | `typos`, `schema-lint`, `cmake-lint` |
| `Makefile` | none | `typos`, `schema-lint`, `checkmake` |
| `service.service` | none | `typos`, `schema-lint`, `systemd-analyze` |
| `README.md` | `rumdl` | `typos`, `schema-lint`, `rumdl` |
| `plain.yaml` | `yamlfmt` | `typos`, `schema-lint` |
| `.github/workflows/ci.yml` | `yamlfmt` | `typos`, `schema-lint`, `actionlint`, `zizmor` |
| `biome.json` | `biome` with self-config guard | `typos`, `schema-lint`, `biome` unless tool-ignored |
| `app.js` | `biome` | `typos`, `schema-lint`, `biome` |
| `component.tsx` | `biome` | `typos`, `schema-lint`, `biome` |
| `style.css` | `biome` | `typos`, `schema-lint`, `biome` |
| `data.jsonc` | `biome` | `typos`, `schema-lint`, `biome` |
| `main.c` | `clang-format` | `typos`, `schema-lint`; `clang-tidy` only when project metadata exists |
| `main.cpp` | `clang-format` | `typos`, `schema-lint`; `clang-tidy` only when project metadata exists |
| `init.lua` | `stylua` | `typos`, `schema-lint`, `selene` |
| `main.rs` | `rustfmt` | `typos`, `schema-lint`, `clippy` or existing Rust lint adapter |
| `Main.java` | `google-java-format` | `typos`, `schema-lint`, `google-java-format` dry-run |
| `index.php` | `php-cs-fixer` | `typos`, `schema-lint`, `php -l` |
| `app.rb` | `rubocop` | `typos`, `schema-lint`, `rubocop` |
| `index.html` | `superhtml` | `typos`, `schema-lint`, `superhtml` |
| `config.toml` | `taplo` | `typos`, `schema-lint`, `taplo` |
| `BUILD` | `buildifier` | `typos`, `schema-lint`, `buildifier` |
| `rules.bzl` | `buildifier` | `typos`, `schema-lint`, `buildifier` |
| `Containerfile` | `dockerfmt` | `typos`, `schema-lint`, `hadolint` |
| `.editorconfig` | none | `typos`, `schema-lint`, `editorconfig-checker` |
| `.gitconfig` | none | `typos`, `schema-lint`, `git config` |
| `crontab` | none | `typos`, `schema-lint`, `crontab` |
| `tmux.conf` | none | `typos`, `schema-lint`, `tmux` |

Dotfiles tests should cover:

- Neovim reads generic capabilities through shdeps
- Neovim falls back to `checkrun capabilities --json`
- formatter/linter maps still point to local `sley` plugin names
- custom filetypes still register
- no use of `capabilities.sley`

Sley tests should cover:

- base hooks still delegate to `autoformat` and `autolint`
- `sley hook lint-file --json` still passes `--json` through
- no Sley registry or verify behavior changes
- `sley hook format-file` remains quiet and advisory for formatter failures
- `sley hook check` still surfaces autolint diagnostics
- changed-file scope and verify command discovery remain untouched

## Drift Prevention

Add tests that fail if:

- Checkrun metadata contains downstream-specific top-level keys
- `checkrun explain` and `checkrun plan` disagree about selected tools
- a registry selector references an adapter that is not implemented
- a registry advertises a tool that execution cannot dispatch
- a shell-function adapter is implemented but never referenced
- an internal adapter is selected by a registry step or dispatched by shell
- a selector references an undefined config policy
- two selectors share the same id
- two adapters share the same id
- registry schema allows unknown fields in non-extension objects
- `autoformat.sh` or `autolint.sh` grows a new filename/extension dispatch
  table outside the registry plan path

The last check should be pragmatic, not brittle. It can start as a focused
grep-based guard around known dispatch smells, then become stricter once the
registry execution path is stable.

## Risks

### Risk: over-declarative registry

Some tools have real quirks that do not belong in JSON. Avoid encoding full
commands and shell conditionals in the registry. Use the registry for selection
and shell adapters for execution.

### Risk: breaking hot editor hooks

Neovim and hooks are latency-sensitive. `checkrun plan` must be fast enough for
one-file calls. Avoid subprocess-heavy config resolution where existing shell
helpers can cheaply answer the question, or cache where appropriate.

### Risk: Python dependency creep

Checkrun already uses Python for schema policy. Keep `registry.py` standard
library only. Do not make core formatting/linting depend on optional Python
packages.

### Risk: partial migration creates more drift

Do not stop after moving `explain` and `capabilities`. The target state is not
achieved until `autoformat` and `autolint` consume registry plans.

### Risk: overbuilt registry language

Keep the registry as a selection model, not a command language or preference
engine. Add only the fields needed to remove drift today: file matching, phase
ordering, adapter ids, path scopes, and config-policy names.

## Completion Criteria

The effort is complete when:

- `share/checkrun/registry.json` is the only Checkrun-owned behavior registry
- `share/checkrun/schemas/registry.schema.json` validates that registry
- `checkrun explain` is registry-backed
- `checkrun capabilities --json` is registry-backed and generic
- `autoformat` and `autolint` execute registry-derived plans
- Neovim/dotfiles consume generic capabilities
- no Checkrun metadata references downstream consumers by name
- tests prove explain/plan/execution consistency for representative filetypes
- the golden-file matrix covers every documented supported filetype
- docs explain how to add a new tool without adding parallel behavior tables
