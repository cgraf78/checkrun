# Test Harness

`test/checkrun-test` is the CI entrypoint. It runs every focused suite under
`test/suites/`; suites share fixture helpers from `test/helpers.sh`. The
timing- and signal-sensitive `autolint-cancellation-test`,
`hook-performance-test`, and `runner-test` run alone first, then
`test/run-suites` runs the remaining suites concurrently
(`CHECKRUN_TEST_JOBS`, default 4).

## Suite Scope

- `checkrun-cli-test` covers user-facing command behavior.
- `registry-launcher-test` covers single-start Python selection and fallback for
  public registry-backed commands.
- `registry-test`, `capabilities-test`, `editor-metadata-test`,
  `schema-lint-test`, and `schema-refresh-test` cover structured APIs and
  schema policy.
- `autoformat-test` and `autolint-test` protect the compatibility commands.
- `autolint-cancellation-test` covers parallel autolint process, signal, and
  scratch-directory lifecycle invariants.
- `verify-test` covers `checkrun verify` project discovery and JSON
  diagnostics for its explicit analyzers.
- `path-policy-test` covers user config and data directory precedence across
  shell and Python.
- `timeout-test` covers the portable timeout fallback without GNU coreutils on
  `PATH`.
- `examples-test` exercises the checked-in consumer examples through public
  APIs.
- `manpage-test` verifies every PATH-visible command has a manual page.
- `runner-test` covers `test/run-suites` result ordering, status preservation,
  and descendant cleanup.
- `harness-test` covers the isolation every suite relies on (a restart without
  the developer's `BASH_ENV`, dropped `CHECKRUN_*` knobs, the cancellation
  suite's signal restart) and how `_skip` results appear in the summary.
- `ci-toolchain-test` validates the CI `mise` lock and the pinned
  `cgraf78/actions` workflow references.
- `hook-performance-test` protects the process count and coarse p95 latency of
  unsupported-file autoformat and autolint paths used by edit hooks.
- `install-test` covers the standalone checkout-backed command and manpage
  links, idempotent retargeting, custom destinations, complete source
  preflight, and refusal to overwrite user-owned paths.
- The required shared Actions gate scans tracked and non-ignored untracked
  files, validates `test/shellcheck-files.txt`, and runs ShellCheck once.
  Inventory records use `program<TAB>path`; reviewed shell fixture exclusions
  use `fixture<TAB>path`.
- `nvim-test` covers the optional Neovim Lua adapter, including host
  materialization of checked editor metadata, dependency URLs, HOME paths, and
  TOML regex keys.
- `linter-probes-test` unit-tests linter adapter probing with mock tools:
  the shellcheckrc fallback translator and the PHP binary probe.

Prefer adding assertions to the suite that owns the API being changed. Registry
changes usually need both registry-level coverage and one behavior test proving
the derived plan or command output is correct.
