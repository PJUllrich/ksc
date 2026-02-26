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

## API

### `Ksc.compile(ksy_path)`

Compiles a `.ksy` file into an Elixir source code string. Returns `{:ok, source}`. Useful for inspecting generated code or writing it to a file.

```elixir
{:ok, source} = Ksc.compile("formats/hello_world.ksy")
# source is a string containing a defmodule with from_file/1 and from_binary/1
```

### `Ksc.compile_and_load(ksy_path)`

Compiles a `.ksy` file and loads the resulting module into the VM. Returns `{:ok, module}`. Automatically handles imports (other `.ksy` files referenced by the format).

```elixir
{:ok, HelloWorld} = Ksc.compile_and_load("formats/hello_world.ksy")
result = HelloWorld.from_file("data.bin")
```

### `Ksc.compile_string_and_load(yaml_string)`

Compiles a KSY format from a YAML string and loads it. Convenient for inline or dynamically generated formats.

```elixir
yaml = """
meta:
  id: my_format
  endian: le
seq:
  - id: magic
    contents: [0x4d, 0x5a]
  - id: length
    type: u4
  - id: name
    type: str
    size: length
    encoding: UTF-8
"""

{:ok, mod} = Ksc.compile_string_and_load(yaml)
result = mod.from_binary(<<0x4d, 0x5a, 5, 0, 0, 0, "Hello">>)
result.length  #=> 5
result.name    #=> "Hello"
```

## Generated Module Interface

Every compiled format produces a module with two public functions:

- **`from_file(path)`** - Reads and parses a binary file, returns a map of parsed fields.
- **`from_binary(binary)`** - Parses a binary directly, returns a map of parsed fields.

The returned map uses atom keys matching the `id` fields in your `.ksy` definition.

## Supported KSY Features

Ksc supports the core Kaitai Struct specification:

- **Primitive types**: `u1`, `u2`, `u4`, `u8`, `s1`, `s2`, `s4`, `s8`, `f4`, `f8`
- **Endianness**: `le`, `be`, and format-level default endian
- **Strings**: `str`, `strz`, sized strings, null-terminated strings, encoding support
- **Byte arrays**: fixed-size, size-from-field, and EOS reads
- **Enums**: named value mappings with expression support
- **User-defined types**: nested type definitions and type references
- **Instances**: computed/lazy fields with value expressions or parsed content
- **Repetition**: `repeat: eos`, `repeat: expr`, `repeat: until`
- **Conditionals**: `if` expressions for optional fields
- **Switch types**: `switch-on` for polymorphic type selection
- **Imports**: cross-file type references (absolute and relative)
- **Expressions**: arithmetic, comparison, string, and array operations
- **Process routines**: `zlib`, `xor`, `rol`, `ror`, and custom process functions
- **Fixed contents**: magic byte validation
- **Sized substreams**: `size` and `size-eos` for bounded reads
- **IO access**: `_io.pos`, `_io.size` for stream introspection
- **Debug mode**: `ks-debug: true` for partial parsing with error recovery

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

## Running Tests

Ksc uses the official [Kaitai Struct test suite](https://github.com/kaitai-io/kaitai_struct_tests) for validation.

```sh
mix deps.get
mix test
```
