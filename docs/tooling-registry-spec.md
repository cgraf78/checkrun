# Checkrun Tooling Registry Spec

## Purpose

Checkrun should have one authoritative model for code-validation behavior. That
model should decide which formatting, linting, schema, spelling, parser, and
type-check tools apply to a file. The same model should drive:

- `autoformat`
- `autolint`
- `checkrun explain`
- `checkrun capabilities`
- editor integrations such as Neovim
- higher-level callers such as Sley

Tool configuration remains outside Checkrun. Dotfiles and project-local config
files own style/rule settings such as `ruff.toml`, `biome.json`, `taplo.toml`,
and ignore files. Checkrun owns the behavior model: file matching, tool
selection, phase ordering, dispatch semantics, and explainability.

## Previous State Before This Refactor

The architecture before this registry work was useful but split-brained:

- `share/checkrun/capabilities.json` describes filetypes, selectors, tools, and
  integration metadata.
- `lib/checkrun/autoformat.sh` and `lib/checkrun/autolint.sh` contain the real
  dispatch tables and phase ordering.
- `lib/checkrun/explain.py` separately implements filetype inference and tool
  selection from `capabilities.json`.
- Dotfiles Neovim config consumes the metadata, but the metadata still exposes a
  downstream-specific `sley` key.

That created drift risk. A new tool or selector could be added to shell dispatch
without updating the metadata, or the metadata can describe behavior that the
shell dispatch does not actually run.

## Target State

Checkrun should ship a versioned registry:

```text
share/checkrun/registry.json
share/checkrun/schemas/registry.schema.json
lib/checkrun/registry.py
```

`registry.json` is the source of truth. The internal `registry.py` interpreter
loads and validates that source of truth, then produces the CLI JSON contracts
for human-facing explanations and machine-facing execution plans.

The physical `capabilities.json` file should be retired. `checkrun capabilities
--json` should emit a derived integration projection from the registry.

## Ownership Boundaries

The durable cross-surface ownership contract is documented in
[`workflow-contract.md`](workflow-contract.md). The registry details below are
the Checkrun-owned implementation of that contract.

Checkrun owns:

- supported filetype identifiers
- editor language-ID aliases for those supported filetypes
- filename, extension, pattern, and shebang matching
- validation phases
- tool identity and ordering
- adapter identity
- default dispatch behavior
- path-scoped tools, such as GitHub Actions linters for workflow YAML only
- config discovery semantics
- fallback config file names and environment roots
- explain and capabilities output
- registry schema and registry interpreter

Dotfiles or project repos own:

- actual config file contents
- global fallback config files under `~/.config/checkrun`
- project-local tool configs
- ignore files under the configured Checkrun config root
- schema association policy instances under `~/.config/checkrun`

Checkrun owns the schema association interpreter and schema for association
policy documents. Dotfiles owns the default association policy instance. The
tooling registry should say that schema validation is a lint phase, but it
should not inline dotfiles-specific schema associations.

Sley owns:

- workflow orchestration
- changed-file scope
- hook timing
- readiness and verify commands
- Sley verify registry schema and behavior

Neovim owns:

- plugin wiring
- mapping Checkrun-derived filetypes to the local formatter/linter plugin named
  `sley`
- editor-specific parser/LSP setup

Checkrun must not contain downstream-specific keys such as `sley`, `nvim`, or
dotfiles-only consumer behavior. Editor language IDs are the exception because
they are not consumer policy: they are aliases for Checkrun's normalized
filetype vocabulary, owned beside filetype inference so all editor surfaces use
the same translation table.

## Fast Check Eligibility

Registry lint selectors are Checkrun's automatic fast-check surface. They feed
`autolint`, `checkrun lint`, and `checkrun check`, so every selected lint step
must be appropriate for editor saves, hooks, and agent changed-file checks.

A selector-owned lint backend is eligible for that surface when:

- it is bounded to the selected file, or to a small owner project that can be
  discovered cheaply from that file
- it runs without network access, package installation, vulnerability database
  updates, full test suites, or broad repository scans
- it returns deterministic diagnostics or fixes without hidden repository
  mutations
- it can no-op cleanly when the backend binary or optional host toolchain is
  missing
- it is gated by project metadata when standalone files would otherwise produce
  noisy, misleading, or expensive results

This rule is about invocation semantics, not tool branding. A type checker,
security scanner, or compiler wrapper can belong in the registry only if its
adapter satisfies the same fast-path contract. Otherwise it belongs in
`checkrun verify` when Checkrun can provide a generic project analyzer, or in a
Sley verify registry when the command is workflow-specific to a repo.

Eligible lint adapters must declare `executionScope: "file"`. The metadata is
not display text; registry validation uses it as the machine-readable gate that
prevents broad project analyzers from drifting back into `checkrun lint` or
`checkrun check` by accident.

Keep this boundary strict because hooks compose Checkrun through Sley. Sley
decides when to run the fast path and readiness workflows; Checkrun decides
which file-derived tools are safe to run automatically when that fast path is
invoked.

## Registry Schema

The registry should be JSON and validated by:

```text
share/checkrun/schemas/registry.schema.json
```

The schema should use `additionalProperties: false` at every object level unless
there is a deliberate extension point. That keeps accidental consumer-specific
fields from becoming de facto API.

Recommended top-level shape:

```json
{
  "version": 1,
  "filetypes": {},
  "editorLanguageIds": { "vscode": {} },
  "selectors": [],
  "crossCutting": {},
  "configPolicies": {},
  "adapters": {}
}
```

The JSON Schema should validate document shape. `registry.py` should enforce
cross-object invariants that are awkward in JSON Schema:

- selector ids are unique
- adapter ids are unique
- every selected step references an existing adapter
- every selected config policy exists
- every config policy references a known environment root
- every phase name is known
- every selector declares at least one normalized filetype
- every filetype named in selectors is declared
- selector-local filename, extension, and pattern matchers are rejected
- every selected shell adapter is implemented and dispatchable
- non-shell `internal` adapters are never selected or dispatched
- no top-level or selector-level consumer-policy keys such as `sley` or `nvim`
  exist
- every `editorLanguageIds` alias references a declared Checkrun filetype and
  has no duplicate editor IDs within a filetype

The seeded registry must resolve metadata drift before it becomes authoritative.
For example, C/C++ `clang-tidy` support is valid only because the registry,
planner, shell dispatch, and tests now share the same gated execution contract.
The registry must not preserve metadata-only tools that execution does not
support.

### Filetypes

`filetypes` maps paths to normalized editor/tooling filetypes.

```json
{
  "filetypes": {
    "extension": {
      "py": "python",
      "rs": "rust",
      "tsx": "typescriptreact"
    },
    "filename": {
      "Dockerfile": "dockerfile",
      "CMakeLists.txt": "cmake"
    },
    "patterns": [
      { "pattern": "Dockerfile.*", "filetype": "dockerfile" },
      { "pattern": "agent-hook-*", "filetype": "sh", "extensionlessOnly": true }
    ],
    "shebangs": [
      { "contains": "zsh", "filetype": "zsh" },
      { "containsAny": ["bash", "/sh"], "filetype": "bash" }
    ]
  }
}
```

This replaces the current `sley.customFiletypes` metadata and the separate
hard-coded extension map in `explain.py`.

Matching order should be deterministic:

1. exact filename
2. extension
3. glob pattern
4. shebang for extensionless text files
5. unknown

Extensionless binary files should be classified as unknown without reading them
as text. Special extensionless files such as `.profile`, `.envrc`, `envrc-*`,
and agent hook files should be covered by registry data instead of hard-coded
consumer logic.

### Editor Language IDs

Editors sometimes use language IDs that differ from Checkrun's normalized
filetypes. For example, VS Code calls shell files `shellscript`, Makefiles
`makefile`, and plain text `plaintext`.

Those aliases belong under `editorLanguageIds` in the registry:

```json
{
  "editorLanguageIds": {
    "vscode": {
      "sh": ["shellscript"],
      "make": ["makefile"],
      "text": ["plaintext"]
    }
  }
}
```

The key is still Checkrun-owned metadata. It does not decide which formatter,
linter, hook, plugin, or editor setting to use; it only translates a supported
Checkrun filetype into editor-native identifiers so consumers do not maintain
their own parallel language maps.

### Selectors

Selectors describe which tools apply to normalized filetypes. Filename,
extension, pattern, and shebang matching belong only in the top-level `filetypes`
table, so editor capabilities and shell execution consume the same path-to-type
answer.

```json
{
  "id": "python",
  "filetypes": ["python"],
  "format": [
    {
      "tool": "ruff",
      "adapter": "ruff-format",
      "config": "ruff-format"
    }
  ],
  "lint": [
    {
      "tool": "ruff",
      "adapter": "ruff-lint",
      "config": "ruff-lint"
    }
  ]
}
```

Each phase array is ordered. Default semantics are `run-all`: every selected
step runs in declaration order if its adapter is available. This preserves
current behavior such as `goimports` followed by `gofumpt`.

If multiple selectors match the same file, the planner should concatenate
matching steps in selector declaration order. Exact duplicate steps should be
deduplicated by phase, tool, adapter, config policy, and path pattern. Similar
but non-identical steps should remain visible rather than being collapsed by
clever inference.

Selectors must not carry their own `extensions`, `filenames`, or `patterns`
matchers. Step-level `pathPatterns` are selector-only: they narrow an already
selected filetype-specific step instead of creating a second filetype inference
table.

Steps may set `requiresConfigMatch` when a tool is not meaningful without
project metadata discovered by its config policy. The planner keeps such a step
out of the executable step list when config resolution returns `source: none`,
and reports it in `skipped` with reason `missing-config`. This keeps project-
contextual tools such as `clang-tidy` visible in the registry while preventing
standalone editor saves from running noisy best-effort lint.

Future alternative-tool preference is intentionally out of scope for the first
registry cutover. Do not add preference or `first-available` machinery until
there is a real second tool for the same phase and filetype; accepting schema
fields before the interpreter implements them would create a new drift surface.

### Phases

Initial supported phases:

- `format`: mutating formatter steps
- `lint`: backend linter steps
- `spell`: spelling checks
- `schema`: schema validation
- `tool`: language/filetype-specific backend linting group

`autolint` currently treats spelling and schema validation as cross-cutting
lint phases before backend tool linting. The registry should preserve that
ordering explicitly.

```json
{
  "crossCutting": {
    "lint": [
      {
        "phase": "spell",
        "tool": "typos",
        "adapter": "typos",
        "config": "typos"
      },
      {
        "phase": "schema",
        "tool": "schema-lint",
        "adapter": "schema-lint"
      }
    ]
  }
}
```

Cross-cutting steps must not declare `pathPatterns`. They are intentionally
global lint phases; path-scoped behavior belongs to selector-owned tool steps,
where the filetype has already been inferred.

### Path-Scoped Tools

Some tools should only apply to a subset of a filetype. GitHub Actions workflow
linting is the current important example:

```json
{
  "id": "yaml",
  "filetypes": ["yaml"],
  "format": [
    { "tool": "yamlfmt", "adapter": "yamlfmt", "config": "yamlfmt" }
  ],
  "lint": [
    {
      "tool": "actionlint",
      "adapter": "actionlint",
      "pathPatterns": ["*/.github/workflows/*.yml", "*/.github/workflows/*.yaml"]
    },
    {
      "tool": "zizmor",
      "adapter": "zizmor",
      "pathPatterns": ["*/.github/workflows/*.yml", "*/.github/workflows/*.yaml"]
    }
  ]
}
```

`checkrun explain`, `checkrun plan`, and execution must use the same
`pathPatterns` matcher.

The matcher should check the same candidate forms everywhere:

- absolute normalized path
- current-working-directory-relative path, when possible
- basename

This preserves current `explain` behavior while making execution match it.

### Config Policies

Config policies describe discovery and fallback rules. The registry should own
which config names matter and where fallback config files are expected. It should
not own the content of those files.

```json
{
  "configPolicies": {
    "ruff-format": {
      "project": [
        { "file": "ruff.toml" },
        { "file": ".ruff.toml" },
        {
          "file": "pyproject.toml",
          "contains": {
            "format": "toml",
            "query": ".tool.ruff // .tool.ruff.format"
          }
        }
      ],
      "fallback": { "file": "ruff.toml" }
    }
  }
}
```

The plan engine should resolve each policy into one of:

- `project`: a project-local config exists
- `fallback`: a config under the configured fallback root exists
- `none`: no config applies
- `native`: the tool should rely on native discovery

Adapters still own CLI details such as `--config`, `--config-path`,
`--config-files`, `-conf`, or `-style=file:...`.

Config root semantics:

- `CHECKRUN_CONFIG_DIR` defaults to `~/.config/checkrun`.
- `~` and environment variables in configured roots should be expanded before
  paths are normalized.
- relative config roots must be resolved to absolute paths before adapters run,
  because several tools change cwd or discover configs from cwd instead of the
  target file path.
- project-local config walks start at the target file directory and walk upward.
- project-local config must win over fallback config.
- fallback config is used only when the fallback file exists.

Policy should support parser-backed config detection such as `pyproject.toml`
with `[tool.ruff]`. If parser support is unavailable, the behavior should match
today's CLI dependency contract rather than silently changing dispatch.

### Adapters

Adapters are Checkrun-internal execution units. The registry should declare each
adapter id so tests can verify that every selected tool has an implementation.

```json
{
  "adapters": {
    "ruff-format": {
      "kind": "shell-function",
      "function": "_format_ruff"
    },
    "ruff-lint": {
      "kind": "shell-function",
      "function": "_lint_ruff"
    }
  }
}
```

The registry should not attempt to encode every command argument as JSON. Tool
quirks are real and already tested in shell adapters. The registry decides that
`ruff-format` applies; the adapter decides how to run it.

Lint adapters that are selected by automatic lint selectors must set
`executionScope: "file"`. Omit that field for formatters, internal adapters, or
project analyzers that are intentionally kept out of `autolint`.

This boundary is important for simplicity. The registry should stay small:
matching rules, phase order, adapter ids, path scopes, and config-policy names.
It should not become a generic command language.

## Registry Interpreter

`lib/checkrun/registry.py` is an internal Checkrun interpreter, not the primary
integration surface. Its public Python facade is deliberately small and listed in
the module's `__all__`; every other helper should be underscore-prefixed so
source-layout convenience does not create accidental API.

The interpreter owns these responsibilities:

- load registry JSON
- validate registry shape and invariants
- infer filetype for a path
- match selectors
- apply path patterns
- apply ignore policy
- resolve config policies
- produce plan entries
- produce capabilities projection

`checkrun explain`, `checkrun plan`, and the private shell execution transport
must all use this interpreter so planning, explanation, and execution cannot
drift. It should be standard-library-only so hot hook paths do not gain optional
Python package dependencies.

Registry loading and validation errors are toolchain errors, not unsupported-file
cases. `checkrun registry`, `checkrun capabilities`, `checkrun explain`, and
`checkrun plan` should print a clear error and exit non-zero when the registry is
missing or invalid. `autoformat` and `autolint` should propagate that registry
failure rather than silently treating every file as unsupported.

The interpreter should not access the network. Planning may inspect local target
files, local config files, ignore files, and local schema association policies,
but it must not fetch schemas or remote metadata.

## CLI API

### `checkrun registry --json`

Print the raw registry. This is mainly for debugging, tests, and integration
inspection. Consumers should prefer derived APIs.

### `checkrun capabilities --json`

Print a generic integration projection:

```json
{
  "version": 2,
  "editorLanguageIds": {
    "vscode": {
      "sh": ["shellscript"],
      "text": ["plaintext"]
    }
  },
  "filetypes": {
    "format": ["python", "go"],
    "lint": ["python", "go", "systemd"],
    "custom": {
      "filename": {},
      "extension": {},
      "patterns": []
    }
  }
}
```

No downstream consumer-policy key should appear in this output. Checkrun-owned
editor language aliases are allowed only because they expose the shared
filetype vocabulary to editor adapters without duplicating policy.

Capabilities output should be sorted and stable so consumers can cache or diff
it. Unknown or unsupported future registry fields should not leak through this
projection until they are intentionally added to the public API.

A selector may declare an empty phase array, such as `"lint": []`, when the
filetype should appear in capabilities for cross-cutting-only behavior. This is
deliberately registry-owned: integration-visible support must not come from
hard-coded defaults in the interpreter.

Formatting support requires at least one formatter step. Lint support is based
on the selector's `lint` key being present, so a format-only selector does not
implicitly appear in `filetypes.lint`.

### `checkrun explain [--json] FILE...`

Explain decisions from the same registry engine that produces execution plans:

- normalized path
- exists
- inferred filetype
- phase ignore decisions
- selected steps
- skipped steps and reasons
- config source
- schema associations

### `checkrun plan --json [--phase format|lint] FILE...`

Emit the stable execution-plan API. `autoformat` and `autolint` use the same
interpreter through a private shell transport, but external consumers should use
this JSON command.

Example:

```json
{
  "version": 1,
  "files": [
    {
      "path": "/repo/app.py",
      "exists": true,
      "filetype": "python",
      "format": {
        "ignored": false,
        "ignore": null,
        "steps": [
          {
            "phase": "format",
            "tool": "ruff",
            "adapter": "ruff-format",
            "config": {
              "policy": "ruff-format",
              "source": "fallback",
              "path": "/home/user/.config/checkrun/ruff.toml"
            }
          }
        ],
        "skipped": [],
        "configDir": "/home/user/.config/checkrun"
      }
    }
  ]
}
```

The plan format is Checkrun API. Keep it stable and versioned enough for tests,
but treat adapter internals as implementation details. When `--phase` is omitted,
the plan should include every known phase. When `--phase` is present, the plan
should include only the requested phase plus any fields needed to explain why
that phase is skipped.

Plan output should include a top-level `version`. Each file entry should include
enough detail to explain skips without requiring the caller to re-run matching:

- `path`
- `exists`
- `filetype`
- phase-level `ignored`
- phase-level ignore source and pattern
- step list
- skipped step list, when relevant
- config resolution result
- missing required infrastructure, when known

Plan generation should not execute formatter or linter tools. It may inspect the
filesystem for target files, config files, ignore files, and schema association
policy files.

Step ordering in plan and JSON diagnostics should be deterministic:
cross-cutting lint phases run before filetype-specific tool lint, and
filetype-specific steps retain selector declaration order after duplicate
deduplication.

### `checkrun lint` and `checkrun check`

Both commands execute the same registry-derived `autolint` behavior. `check` is
a naming alias for callers that model the fast hook/editor operation as a check
rather than a lint command; it must not grow a separate tool-selection path.

`checkrun verify` is the companion path for generic analyzers that are useful in
readiness workflows but too broad for the automatic lint contract. Callers pass
files or directories; Checkrun discovers the owning projects and decides which
verify-time tools apply.

## Schema Association API

`lib/checkrun/schemas/schema_policy.py` is dependency-addressable through
shdeps, so its public API must stay explicit:

- `schema_policy.py --lsp-schemas`
- the functions listed in `schema_policy.__all__`

The `--lsp-schemas` projection is named for the data shape it emits, not for one
specific editor consumer. Helpers outside `__all__` should remain
underscore-prefixed implementation details.

## Dispatch Flow

Formatter flow:

```text
autoformat
  -> parse CLI flags, preserving `--` separator behavior
  -> normalize input files
  -> ask the private registry shell-plan transport for a format plan
  -> for each file plan
       -> if ignored, skip
       -> for each step
            -> dispatch adapter id
            -> adapter applies tool-specific command behavior
```

Linter flow:

```text
autolint
  -> parse --fix/--json, preserving `--` separator behavior
  -> normalize input files
  -> ask the private registry shell-plan transport for a lint plan
  -> for each file plan
       -> run cross-cutting spell/schema steps unless ignored
       -> run backend tool steps unless tool-ignored
       -> preserve current batching behavior for read-only lint
```

Missing tools remain graceful no-ops. Missing required infrastructure such as
`yq` and `jq` should keep current behavior unless the implementation explicitly
proves a narrower requirement is safe.

The private shell-plan transport is intentionally not documented as integration
API. It exists only so Bash callers can consume NUL-delimited fields without
trying to store NUL bytes in variables; external consumers should use
`checkrun plan --json`.

Intentional exit-code behavior should remain explicit:

- `autoformat` exits 0 for unsupported files, missing tools, missing files,
  ignored files, and formatter failures. Formatter stderr should surface only
  when useful, matching current save-hook behavior.
- `autolint` exits 0 for unsupported files, missing tools, missing files, and
  ignored files.
- `autolint` exits non-zero when selected linters report findings or tool
  errors.
- `autolint --fix` remains sequential to avoid project-scope fix races.
- read-only `autolint` may batch independent files, preserving current bounded
  concurrency behavior.

Path arguments beginning with `-` must continue to work when callers insert
`--`. Sley and editor hooks rely on this for hostile or unusual filenames.

## Cutover

This is a single-user toolchain today, so prefer a clean cutover over temporary
compatibility shims. Do not emit both the generic capabilities shape and the old
`sley` shape. Update Checkrun and dotfiles together, verify both, then push both
repos when the new contract is green.

The implementation should still preserve intentional workflow behavior, such as
missing-tool no-ops, phase-specific ignores, and `autolint --json`, unless the
new registry design deliberately replaces that behavior.

## Non-Goals

- Do not move fallback config files into Checkrun.
- Do not make Sley consume registry internals directly.
- Do not rewrite all execution in Python.
- Do not generate shell dispatch into checked-in files.
- Do not add user preference logic until there are multiple real tool choices
  for the same phase and filetype.
