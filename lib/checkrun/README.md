# checkrun Libraries

This directory owns checkrun's reusable implementation. The public commands in
`bin/` and optional integrations should call into these modules instead of
reimplementing registry or schema-policy logic.

## Files

- `common.sh` contains shared shell helpers for command wrappers.
- `autoformat.sh` and `autolint.sh` implement the legacy focused command
  behavior on top of the shared registry model.
- `registry.py` is the registry interpreter used by `checkrun plan`,
  `checkrun explain`, and tests.
- `nvim.lua` is the Neovim adapter API for filetype and YAML schema
  integration.
- `schemas/` owns schema association policy and schema-lint entrypoints.
- `linters/` groups shell functions by tooling domain. Keep new backend logic
  in the closest existing domain file unless a new domain has clear ownership.

## Registry Contract

`share/checkrun/registry.json` is the durable source of formatter/linter
vocabulary. Library code may normalize or validate that registry, but callers
should not duplicate filetype, phase, or tool-selection rules.

Lint adapters selected by the registry run through the fast `autolint` path used
by editors, hooks, and `checkrun check`. Keep adapter work bounded to the target
file or cheap owner-project context; broader project analyzers belong in
`verify.py` or a caller-owned Sley verify workflow instead of registry lint
selectors.
