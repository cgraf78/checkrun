# Test Harness

`test/checkrun-test` is the CI entrypoint. It loads `test/helpers.sh` and runs
the focused suites under `test/suites/`.

## Suite Scope

- `checkrun-cli-test` covers user-facing command behavior.
- `registry-test`, `capabilities-test`, `schema-lint-test`, and
  `schema-refresh-test` cover structured APIs and schema policy.
- `autoformat-test` and `autolint-test` protect the compatibility commands.
- `nvim-test` covers the optional Neovim Lua adapter.

Prefer adding assertions to the suite that owns the API being changed. Registry
changes usually need both registry-level coverage and one behavior test proving
the derived plan or command output is correct.
