# AGENTS.md

## About

`checkrun` owns formatter, linter, and file-check dispatch for the
`checkrun`, `autoformat`, and `autolint` CLIs. Callers own *when* those
semantics run. The cross-surface contract is
[docs/workflow-contract.md](docs/workflow-contract.md).

## Architecture

- `share/checkrun/registry.json` is the durable source of filetype,
  phase, and tool-selection vocabulary. Do not duplicate those rules
  in adapters, editors, or hooks.
- `lib/checkrun/` owns the implementation. `bin/` entry points are
  thin dispatchers.
- `lib/checkrun/registry.py` interprets the registry for `plan`,
  `explain`, and capabilities.
- `lib/checkrun/verify.py` owns explicit project analyzers (Go/Rust/C++
  owner-root checks). Keep those off the save-time lint path.
- `lib/checkrun/linters/` groups shell adapters by tooling domain.

## Invariants

- `checkrun lint`, `checkrun check`, and `autolint` are one fast
  automatic path. Registry lint adapters must stay file-scoped
  (`executionScope: "file"`).
- Broader, slow, or project-scoped analyzers belong in
  `checkrun verify` or a caller-owned Sley verify workflow.
- Missing optional language tools are graceful no-ops.
- `autoformat` mutates eligible files and exits 0 even when a
  formatter fails, so save-time hooks can surface stderr without
  blocking.
- Tool config contents (`ruff.toml`, ignore files, schema association
  policy) are owned by dotfiles or the project repo, not by Checkrun.

## Testing

CI (`test/checkrun-test`; ShellCheck is the shared inventory job):

```sh
test/checkrun-test
```

Local ShellCheck uses `test/shellcheck-files.txt`. Registry changes
need both registry-level coverage and one behavior test that the
derived plan or command output is correct.
