# Public API Manifest

> **Source of truth:** this file is compared against `src/toml.zig`
> in CI (`api-drift` job) and by `tests/docs_hygiene_test.zig` on
> every local `zig build test`. Any change to the re-exported surface
> MUST land in the same merge request that updates this file, or CI
> will fail.

Regenerate the live symbol list locally via:

```bash
grep -nE '^pub (const|fn) ' src/toml.zig \
  | awk '{
      for (i=1; i<=NF; i++) {
        if ($i == "const" || $i == "fn") {
          name = $(i+1);
          sub(/[(=:].*$/, "", name);
          print $i, name;
          break;
        }
      }
    }' \
  | sort -u
```

## Re-exported symbols (as of 0.2.0 + Unreleased)

```text
const DateLocal
const DateTime
const DateTimeLocal
const Document
const EncodeOptions
const ErrorCode
const ParseError
const ParseOptions
const ArrayOpts
const Decoded
const DecodeError
const Diagnostic
const DiagnosticCode
const DiagnosticList
const FieldSchema
const FloatOpts
const IntOpts
const ParseResult
const SchemaError
const SchemaNode
const SchemaValidator
const StringOpts
const TimeLocal
const TomlVersion
const UnknownFieldPolicy
const Value
const ValueTag
const decode
const encoder
const encoder_cli
const error_mod
const json_tagged
const parallel
const parser_mod
const schema
const value_mod
fn encode
fn parse
fn parseWithError
fn writeTaggedJson
```

## Drift policy

- **Adding a `pub` symbol:** append to the list above in the same
  commit, call it out in `CHANGELOG.md` under `### Added`.
- **Removing a `pub` symbol:** a semver-major event. Remove here,
  call it out in `CHANGELOG.md` under `### Removed`, bump the major
  version.
- **Renaming a `pub` symbol:** a semver-major event. Treat as
  remove + add.
- **Type changes** (e.g. `fn parse` signature): do not appear in
  this flat list; cover them via the hand-written signature docs in
  `docs/API.md` and the unit tests in `tests/accept.zig`.

## How the gate works

Two independent gates enforce this manifest:

1. **Local:** `tests/docs_hygiene_test.zig` extracts every
   `pub const|fn NAME` from `src/toml.zig` and asserts that
   `const NAME` or `fn NAME` appears as a substring in this file.
   Runs on every `zig build test`.
2. **CI:** the `.gitlab-ci.yml :: api-drift` job reduces both
   `src/toml.zig` and `docs/PUBLIC_API.md` to a canonical `kind name`
   sorted list and `diff -u`s them. Any asymmetry fails the
   pipeline.
