# Test Harness

`test/checkrun-test` is the CI entrypoint. It loads `test/helpers.sh` and runs
the focused suites under `test/suites/`.

## Suite Scope

- `checkrun-cli-test` covers user-facing command behavior.
- `registry-launcher-test` covers single-start Python selection and fallback for
  public registry-backed commands.
- `registry-test`, `capabilities-test`, `editor-metadata-test`,
  `schema-lint-test`, and `schema-refresh-test` cover structured APIs and
  schema policy.
- `autoformat-test` and `autolint-test` protect the compatibility commands.
- `hook-performance-test` protects the process count and coarse p95 latency of
  unsupported-file autoformat and autolint paths used by edit hooks.
- The required shared Actions gate scans tracked and non-ignored untracked
  files, validates `test/shellcheck-files.txt`, and runs ShellCheck once.
  Inventory records use `program<TAB>path`; reviewed shell fixture exclusions
  use `fixture<TAB>path`.
- `nvim-test` covers the optional Neovim Lua adapter.

Prefer adding assertions to the suite that owns the API being changed. Registry
changes usually need both registry-level coverage and one behavior test proving
the derived plan or command output is correct.
