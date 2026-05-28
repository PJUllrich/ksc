# Ksc

An Elixir implementation of the [Kaitai Struct](https://kaitai.io/) compiler and runtime. Ksc compiles `.ksy` format descriptions into Elixir modules that parse binary data into structured maps.

## Installation

Add `ksc` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ksc, "~> 0.1.0"}
  ]
end
```

## Quick Start

Given a Kaitai Struct format definition (`hello_world.ksy`):

```yaml
meta:
  id: hello_world
seq:
  - id: one
    type: u1
```

Compile it to an Elixir source file:

```sh
mix ksc.compile hello_world.ksy --output lib/formats
```

This writes `lib/formats/hello_world.ex` containing a `Ksc.Compiled.HelloWorld` module. You can also point it at a directory to compile all `.ksy` files at once:

```sh
mix ksc.compile my_formats/ --output lib/formats
```

Use `--namespace` to set a custom module prefix (default: `Ksc.Compiled`):

```sh
mix ksc.compile my_formats/ --output lib/formats --namespace MyApp.Formats
```

Then use the generated module to parse binary data:

```elixir
result = Ksc.Compiled.HelloWorld.from_file("data.bin")
result.one
#=> 80

result = Ksc.Compiled.HelloWorld.from_binary(<<42>>)
result.one
#=> 42
```

## Example: Parsing with Enums

```yaml
# enum_0.ksy
meta:
  id: enum_0
  endian: le
seq:
  - id: pet_1
    type: u4
    enum: animal
  - id: pet_2
    type: u4
    enum: animal
enums:
  animal:
    4: dog
    7: cat
    12: chicken
```

```elixir
{:ok, mod} = Ksc.compile_and_load("enum_0.ksy")
result = mod.from_binary(<<7, 0, 0, 0, 12, 0, 0, 0>>)
result.pet_1  #=> :cat
result.pet_2  #=> :chicken
```

## Write-back

Ksc can also serialize a parsed map back into binary. Pass `writer: true` at
compile time to generate `to_binary/1` and `to_file/2` alongside the readers:

```sh
mix ksc.compile hello_world.ksy --output lib/formats --writer
```

or programmatically:

```elixir
{:ok, mod} = Ksc.compile_and_load("hello_world.ksy", writer: true)

data = mod.from_binary(File.read!("in.bin"))
data = put_in(data, [:header, :version], 2)
File.write!("out.bin", mod.to_binary(data))
```

### Length / count fields

When a `size:` or `repeat-expr:` reads from another seq field (a "controller"),
the writer overwrites that controller from the actual payload before emitting
bytes — so you can freely grow or shrink a controlled field without touching
the length field:

```yaml
seq:
  - id: name_len
    type: u2
  - id: name
    size: name_len
```

```elixir
m = mod.from_binary(<<5, 0, "hello">>)
mod.to_binary(%{m | name: "goodbye"})  #=> <<7, 0, "goodbye">>
#                                                 ^^ writer auto-updated name_len
```

Supported controller expressions: a bare field reference (`size: foo`) or a
single arithmetic op with an integer literal (`size: foo + 8`, `size: 100 - foo`,
`size: foo * 2`, `size: foo / 4`). Multiplicative/divisive forms raise
`:non_invertible_controller` if the actual length doesn't divide cleanly.

For non-simple expressions (`size: header.x * 2`, `size: 16`), the writer keeps
strict semantics: pads with `pad-right` (or zero) when the payload is shorter
than declared, raises `:size_overflow` when longer.

### v1 limitations

- **Encodings on write**: UTF-8, ASCII, UTF-16LE, UTF-16BE. SJIS / IBM437 raise.
- **Instances are not written**. Value instances (computed from other fields)
  are recomputed on the next read. Positional instances are lost on write-back.
- **`process: zlib`** writes are semantically correct but not byte-identical
  (re-compression).
- **Custom `process:` modules** must implement `encode/2` for write-back.
- **Switch types with no `_` case**: rely on parser-stashed raw bytes in the map.

## Running Tests

Ksc uses the official [Kaitai Struct test suite](https://github.com/kaitai-io/kaitai_struct_tests) for validation.

```sh
mix deps.get
mix test
```

Additional write-back test suites (opt-in via tag):

```sh
# Broad round-trip test: parse → to_binary → from_binary → assert equal
mix test --only writer_roundtrip

# Broad mutation test: parse → mutate every field → to_binary → from_binary → assert equal
mix test --only writer_mutation

# Reproduce a specific mutation seed
MUTATION_SEED=42 mix test --only writer_mutation
```
