# Test Harness

`test/checkrun-test` is the CI entrypoint. It loads `test/helpers.sh` and runs
the focused suites under `test/suites/`.

## Suite Scope

- `checkrun-cli-test` covers user-facing command behavior.
- `registry-test`, `capabilities-test`, `schema-lint-test`, and
  `schema-refresh-test` cover structured APIs and schema policy.
- `autoformat-test` and `autolint-test` protect the compatibility commands.
- `shellcheck-test` scans tracked and non-ignored untracked files across the
  repository, validates the typed shell-file inventory, and runs ShellCheck
  with sourced dependencies enabled. Inventory records use `program<TAB>path`;
  reviewed shell fixture exclusions use `fixture<TAB>path`. CI runs these
  suites in a dedicated dependency-profile job; the named Checkrun setup job
  delegates them because its Alpine path intentionally skips the mise tools.
- `nvim-test` covers the optional Neovim Lua adapter.

Prefer adding assertions to the suite that owns the API being changed. Registry
changes usually need both registry-level coverage and one behavior test proving
the derived plan or command output is correct.
