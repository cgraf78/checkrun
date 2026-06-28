# Checkrun Workflow Contract

## Purpose

Checkrun is the low-level language policy engine for code-editing workflows.
Humans, agents, editor integrations, Git hooks, Sapling hooks, and higher-level
workflow tools should all see the same answer for a file: what type it is,
which fast tools may run automatically, which diagnostics are produced, and
which broader checks require explicit verification.

This contract keeps that answer centralized. Checkrun owns language and tool
semantics; callers own when those semantics are invoked.

## Ownership Model

Checkrun owns:

- normalized filetype identifiers and path-to-filetype inference
- editor language-ID aliases for supported filetypes
- formatter, linter, spell-check, schema-check, and analyzer tool identity
- phase ordering for format, lint, spelling, schema, and tool-specific checks
- adapter identity and default dispatch behavior
- config discovery semantics, including project metadata gates
- the fast automatic surface exposed by `checkrun lint`, `checkrun check`, and
  `autolint`
- explicit project analyzer execution exposed by `checkrun verify`
- JSON contracts for capabilities, plans, explanations, schema policy, and
  diagnostics

Sley owns:

- repo selection, changed-file scope, and commit-input scope
- hook timing and caller policy for humans, agents, editors, Git, and Sapling
- readiness orchestration through `sley ready`
- workflow command discovery through `sley verify`
- extension points that decide when to call Checkrun or project-owned commands

Editor adapters own protocol translation only. A VS Code or Neovim integration
may translate Checkrun and Sley APIs into editor-native settings, formatters,
linters, diagnostics, and commands, but it should not carry independent
language maps, tool-selection tables, or fast-check policy.

Dotfiles and project repos own configuration contents: fallback config files,
project-local tool configs, ignore files, and schema association policy
instances. Checkrun may interpret those files, but it must not become the owner
of their contents.

## Invocation Surfaces

`checkrun format` and `autoformat` are the mutating format path. They use the
registry to choose formatter adapters for the supplied files.

`checkrun lint`, `checkrun check`, and `autolint` are one fast automatic lint
path with multiple names. `check` exists for callers that describe the hook or
editor operation as a check, but it must not grow separate tool selection from
`lint`.

`checkrun verify` is the explicit project-check path. It is for checks that are
generic enough for Checkrun to own, but too broad, slow, or project-scoped to run
from save-time editor lint. The command accepts changed files or directories and
then chooses the owning Go modules, Rust projects, and C/C++ files itself so
callers do not need to know language-specific analyzer rules. Missing paths are
preserved as scope hints: deleted or renamed Go/Rust files still select the
nearest surviving owning module/project, and deleted C/C++ files select the
nearest surviving directory context for metadata-gated `clang-tidy`.

Sley may call these surfaces, but it should not invoke underlying tools such as
`ruff`, `mypy`, `actionlint`, `zizmor`, `cargo-audit`, or `govulncheck`
directly unless a repo-specific verify command intentionally owns that workflow.
That rule keeps low-level tool invocation behind Checkrun's language policy and
keeps repo-specific workflows behind Sley's verify registry.

## Fast Automatic Checks

The fast automatic surface is safe for editor saves, agent hooks, and changed
files. A Checkrun registry lint step belongs there only when it:

- is bounded to the selected file or to a small owner project discovered cheaply
  from that file
- does not require network access, dependency installation, vulnerability
  database updates, full test suites, or broad repository scans
- emits deterministic diagnostics or fixes without hidden repository mutations
- treats missing optional tools as graceful no-ops
- is gated by explicit project metadata when standalone files would produce
  noisy, misleading, or expensive results

This is a semantic rule, not a tool-category rule. A type checker or compiler
wrapper can be automatic when its adapter satisfies the same fast-path contract.
Otherwise it belongs in `checkrun verify` or in a Sley verify registry. Registry
lint adapters mark this explicitly with `executionScope: "file"`; validation
rejects automatic lint selectors that point at broader adapters.

Verify-time checks may still be automatic at the workflow layer. Sley can pass
its changed-file set to `checkrun verify`, and Checkrun decides which broader
generic analyzers apply. That keeps hook policy automatic without moving
low-level language invocation back into Sley.

## Consistency Requirements

Every code-editing surface should consume the same public APIs:

- use `checkrun capabilities --json` for supported filetypes and editor
  language-ID aliases
- use `checkrun plan --json` or the Checkrun CLIs for formatter and linter
  decisions
- use Checkrun schema-policy APIs for editor/LSP schema associations
- use Checkrun JSON diagnostics as the producer-owned diagnostic contract
- use Sley hook APIs when the caller needs repo scope, hook timing, or
  human/agent workflow policy

Do not add a parallel language map, selector table, or direct low-level tool
dispatcher in an editor adapter, dotfiles hook, or Sley workflow path. If a new
filetype or fast check should be available everywhere, add it to Checkrun first.
If a new project workflow should count toward readiness, add it to Sley verify
or to a repo-owned verify registry.

## Change Checklist

When changing language or workflow policy:

1. Add filetype inference, editor aliases, selectors, and config gates in the
   Checkrun registry.
2. Keep `checkrun capabilities`, `checkrun explain`, `checkrun plan`,
   `autoformat`, and `autolint` derived from the same registry behavior.
3. Verify each new automatic lint step satisfies the fast-check contract.
4. Put broad generic project analyzers in `checkrun verify`; reserve Sley
   verify registry entries for repo-specific workflows.
5. Update editor and hook integrations to consume the public Checkrun or Sley
   API, not copied policy.
6. Add consistency tests when more than one surface depends on the behavior.
