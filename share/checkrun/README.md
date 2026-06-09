# Shared Runtime Data

Files here are installed data consumed by checkrun commands and integrations.
Treat them as part of the runtime interface.

## Files

- `registry.json` is the canonical formatter, linter, filetype, and capability
  registry.
- `schemas/registry.schema.json` validates the registry shape.
- `schemas/associations.schema.json` validates user schema association files.
- `shell.sh` is a stable loader path for shell integrations. It is intentionally
  small because checkrun behavior lives in `bin/` and `lib/checkrun/`.

Registry changes should include focused tests for both the JSON shape and the
derived command behavior that depends on the new entry.
