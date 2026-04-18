# toml-test corpus (vendored subset)

This directory contains a curated subset of the BurntSushi/toml-test
corpus (<https://github.com/toml-lang/toml-test>), pinned at tag
`v1.5.0`. It is vendored here so `zig build test` has a stable
conformance signal without network access.

- `valid/`      -- inputs that MUST parse successfully; each `<name>.toml`
                   has a matching `<name>.json` tagged-JSON fixture.
- `invalid/`    -- inputs that MUST fail to parse.
- `known_failing/` -- cases that currently diverge from the spec; each
                   entry has a tracking ticket referenced in a sibling
                   `<name>.toml.md` note.

License: MIT (see LICENSE). To refresh, bump `TOML_TEST_VERSION` in
`.gitlab-ci.yml` and re-vendor by hand (follow-up script TBD).
