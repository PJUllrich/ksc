# Changelog

## v0.2.0 — 2026-05-29

- **Write-back.** Compile with `writer: true` (`--writer`) to generate
  `to_binary/1` and `to_file/2`, inverting every read operation.
- **Automatic length/count controllers**: `size:`/`repeat-expr:` fields are
  recomputed from the actual payload on write.
- `process: xor` with a multi-byte key is now ~5× faster.

## v0.1.0 — 2026-02-26

Initial release: a Kaitai Struct compiler and parsing runtime for Elixir.

- `mix ksc.compile` turns `.ksy` files into Elixir modules with `from_binary/1`
  and `from_file/1`.
- Covers integers/floats, bit fields, enums, strings/encodings, user and switch
  types, repeats, instances, expressions, and `process` steps.
- Validated against the official Kaitai Struct test suite.
