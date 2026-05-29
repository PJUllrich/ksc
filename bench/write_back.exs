# Runtime benchmark for write-back (`to_binary/1`) generated code + Stream helpers.
#
#   mix run bench/write_back.exs
#
# Picks a handful of formats that exercise distinct writer paths, builds a large
# parsed map for each, and times `to_binary/1` over many iterations with
# :timer.tc (no external deps). Prints median ns/op so runs are comparable.

defmodule Bench do
  def compile(yaml) do
    ns = "Bench#{:erlang.unique_integer([:positive])}"
    {:ok, mod} = Ksc.compile_string_and_load(yaml, namespace: ns, writer: true)
    mod
  end

  # Median wall-clock per call, in microseconds, over `samples` batches of `batch` calls.
  def measure(fun, batch \\ 2_000, samples \\ 25) do
    # warmup
    for _ <- 1..batch, do: fun.()

    times =
      for _ <- 1..samples do
        {us, _} = :timer.tc(fn -> for _ <- 1..batch, do: fun.() end)
        us / batch
      end

    sorted = Enum.sort(times)
    median = Enum.at(sorted, div(length(sorted), 2))
    {median, Enum.min(sorted)}
  end

  def run(name, mod, map) do
    bin = mod.to_binary(map)
    {median, min} = measure(fn -> mod.to_binary(map) end)

    :io.format("~-28s ~10.3f us/op (min ~10.3f)  out=~B bytes~n", [
      name,
      median,
      min,
      byte_size(bin)
    ])
  end
end

# ---------------------------------------------------------------------------
# 1. Large repeated primitive array (iodata building + primitive write path).
prims_yaml = """
meta:
  id: prim_array
  endian: le
seq:
  - id: values
    type: u4
    repeat: eos
"""

prims_mod = Bench.compile(prims_yaml)
prims_bin = for i <- 1..4000, into: <<>>, do: <<rem(i * 2_654_435_761, 0x100000000)::32-little>>
prims_map = prims_mod.from_binary(prims_bin)

# 2. Repeated user type (nested to_binary calls + reduce).
user_yaml = """
meta:
  id: points
  endian: le
seq:
  - id: items
    type: point
    repeat: eos
types:
  point:
    seq:
      - id: x
        type: u2
      - id: y
        type: u2
      - id: label
        type: str
        size: 4
        encoding: ASCII
"""

user_mod = Bench.compile(user_yaml)
user_bin = for _ <- 1..2000, into: <<>>, do: <<1, 0, 2, 0, "abcd">>
user_map = user_mod.from_binary(user_bin)

# 3. XOR-processed byte blob (process inverse path).
xor_yaml = """
meta:
  id: xored
seq:
  - id: data
    size-eos: true
    process: xor(0x5A)
"""

xor_mod = Bench.compile(xor_yaml)
xor_bin = :binary.copy(<<0xAB>>, 16_000)
xor_map = xor_mod.from_binary(xor_bin)

# 3b. XOR with a multi-byte key (the path rewritten to use :crypto.exor).
xor_key_yaml = """
meta:
  id: xored_key
seq:
  - id: data
    size-eos: true
    process: xor([1, 2, 3, 4, 5, 6, 7])
"""

xor_key_mod = Bench.compile(xor_key_yaml)
xor_key_bin = :binary.copy(<<0xAB>>, 16_000)
xor_key_map = xor_key_mod.from_binary(xor_key_bin)

# 4. Bit-packed repeated field (repeat_write_bits).
bits_yaml = """
meta:
  id: bitfield
seq:
  - id: flags
    type: b3
    repeat: eos
"""

bits_mod = Bench.compile(bits_yaml)
bits_bin = :binary.copy(<<0b10110100>>, 3000)
bits_map = bits_mod.from_binary(bits_bin)

# 5. Sized strings with a length controller (controller pre-pass + str write).
str_yaml = """
meta:
  id: strs
  endian: le
seq:
  - id: len
    type: u4
  - id: text
    type: str
    size: len
    encoding: UTF-8
"""

str_mod = Bench.compile(str_yaml)
str_bin = (fn -> body = :binary.copy("x", 8000); <<byte_size(body)::32-little, body::binary>> end).()
str_map = str_mod.from_binary(str_bin)

IO.puts("")
IO.puts("=== write-back to_binary/1 benchmark ===")
Bench.run("u4 array (x4000)", prims_mod, prims_map)
Bench.run("user type array (x2000)", user_mod, user_map)
Bench.run("xor size-eos (16KB)", xor_mod, xor_map)
Bench.run("xor multi-byte key (16KB)", xor_key_mod, xor_key_map)
Bench.run("b3 array (x8000)", bits_mod, bits_map)
Bench.run("sized str + controller (8KB)", str_mod, str_map)
IO.puts("")
