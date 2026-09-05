# Protocol tests

`lore test protocols [pytest arguments]` runs the `tests/protocols` directory owned by the resolved CLI/scripts checkout. The working directory and personal installed tests do not select the suite. A missing directory fails explicitly. The installed scripts symlink resolves back to the same checkout, so no separate test installation is needed.

The helpers read `skills`, `agents`, `claude-md`, and `scripts` relative to this directory. Tests that invoke hooks supply an isolated store and explicit framework so personal settings cannot bypass the tested path.

Run `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 lore test protocols -q` for an isolated pytest environment; this suite needs pytest and PyYAML, but no third-party pytest plugins. Additional arguments are forwarded unchanged.

## Coverage ownership

`recovery-inventory.json` records every test function from the 23 formerly installed Python files. Retained functions live here under the original filenames, except the older `test_conventions.py` is named `test_legacy_conventions.py` to preserve the existing candidate conventions suite. The inventory gives the reason and current coverage owner for each retired function; retirement does not delete personal installed copies.

Removed skills (`self-test`, `pr-revise`, `pr-self-review`) are not recreated. Old inline implementation and retrospective pipelines are covered by their current command/recipe suites. Updated retained checks follow current phase-level design context, schema field tables, consultation headings, and source instruction fragments. Historical expected failures for retired promotion stages are removed; previously passing expected failures are now ordinary assertions.

The Tier 2 schema check preserves required-field parity. Runtime validation is covered by `tests/test_validate_tier2.sh`; the current schema document no longer embeds example rows. Tier 3 no longer has a standalone schema/validator pair.

## Recipe fixtures

`tests/helpers/implement_recipes.py` requires an already installed Go version at least as new as `tui/go.mod`. It uses `LORE_TEST_GO` when supplied, otherwise `go` on PATH, and refuses incompatible versions without downloading a toolchain. The selected binary directory is prepended to fixture PATH and `GOTOOLCHAIN=local` is fixed. Module/build caches are shared scratch directories outside the disposable case root. A read-only module cache therefore cannot prevent case-HOME teardown.
