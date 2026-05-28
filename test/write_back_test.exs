defmodule WriteBackTest do
  @moduledoc """
  Targeted unit tests for write-back. Each test compiles a small inline KSY,
  parses a fixture binary, optionally mutates the map, writes it back, and
  asserts either byte-equality (round-trip) or specific field invariants
  (mutation).
  """

  use ExUnit.Case, async: false

  defp load(yaml) do
    ns = "WB#{:erlang.unique_integer([:positive])}"
    {:ok, mod} = Ksc.compile_string_and_load(yaml, namespace: ns, writer: true)
    mod
  end

  describe "primitive round-trip" do
    test "u1 / u2le / u4be / s2le / f4le" do
      yaml = """
      meta:
        id: prims
      seq:
        - id: a
          type: u1
        - id: b
          type: u2le
        - id: c
          type: u4be
        - id: d
          type: s2le
        - id: e
          type: f4le
      """

      mod = load(yaml)
      bin = <<42, 0x34, 0x12, 0xDE, 0xAD, 0xBE, 0xEF, 0xFF, 0xFF>> <> <<1.5::float-little-32>>
      m = mod.from_binary(bin)
      assert m.a == 42
      assert m.b == 0x1234
      assert m.c == 0xDEADBEEF
      assert m.d == -1
      assert m.e == 1.5
      assert mod.to_binary(m) == bin
    end
  end

  describe "bit fields" do
    test "mixed bit widths round-trip" do
      yaml = """
      meta:
        id: bits_mix
      seq:
        - id: a
          type: b1
        - id: b
          type: b3
        - id: c
          type: b4
        - id: d
          type: u1
      """

      mod = load(yaml)
      # 0xC5 = 1100 0101 -> a=1(true), b=100=4, c=0101=5; d=0xFF
      bin = <<0xC5, 0xFF>>
      m = mod.from_binary(bin)
      assert m.a == true
      assert m.b == 4
      assert m.c == 5
      assert m.d == 0xFF
      assert mod.to_binary(m) == bin
    end

    test "1-bit boolean mutates via boolean" do
      yaml = """
      meta:
        id: bit1
      seq:
        - id: flag
          type: b1
        - id: pad
          type: b7
      """

      mod = load(yaml)
      m = mod.from_binary(<<0b10000000>>)
      assert m.flag == true
      out = mod.to_binary(%{m | flag: false})
      assert out == <<0b00000000>>
    end
  end

  describe "enum" do
    test "round-trip + mutate via atom" do
      yaml = """
      meta:
        id: enum_demo
      seq:
        - id: kind
          type: u1
          enum: animal
      enums:
        animal:
          1: dog
          2: cat
          3: bird
      """

      mod = load(yaml)
      m = mod.from_binary(<<2>>)
      assert m.kind == :cat
      assert mod.to_binary(m) == <<2>>
      out = mod.to_binary(%{m | kind: :bird})
      assert out == <<3>>
    end
  end

  describe "controller pre-pass — auto-update length fields" do
    test "identity: size: foo" do
      yaml = """
      meta:
        id: ident
        endian: le
      seq:
        - id: len
          type: u2
        - id: data
          size: len
      """

      mod = load(yaml)
      m = mod.from_binary(<<3, 0, ?a, ?b, ?c>>)
      assert m.data == "abc"
      # Grow without touching :len — writer updates it
      out = mod.to_binary(%{m | data: "hello world"})
      assert out == <<11, 0>> <> "hello world"
    end

    test "{:add, n}: size: foo - 8" do
      yaml = """
      meta:
        id: addn
        endian: le
      seq:
        - id: total_len
          type: u2
        - id: header
          size: 8
        - id: body
          size: total_len - 8
      """

      mod = load(yaml)
      # total_len = 8 (header) + 3 (body) = 11
      bin = <<11, 0>> <> :binary.copy(<<0xAA>>, 8) <> "abc"
      m = mod.from_binary(bin)
      assert m.body == "abc"
      assert mod.to_binary(m) == bin
      # Grow body to 5 bytes — writer recomputes total_len = 8 + 5 = 13
      out = mod.to_binary(%{m | body: "abcde"})
      assert <<13, 0, _hdr::binary-size(8), "abcde">> = out
    end

    test "{:sub, n}: size: foo + 1 (writer subtracts)" do
      yaml = """
      meta:
        id: subn
        endian: le
      seq:
        - id: payload_len_minus_one
          type: u2
        - id: payload
          size: payload_len_minus_one + 1
      """

      mod = load(yaml)
      # value 2 means 3 bytes
      bin = <<2, 0, ?a, ?b, ?c>>
      m = mod.from_binary(bin)
      assert m.payload == "abc"
      assert mod.to_binary(m) == bin
      # Grow to 5 bytes — controller becomes 4
      out = mod.to_binary(%{m | payload: "abcde"})
      assert out == <<4, 0, ?a, ?b, ?c, ?d, ?e>>
    end

    test "{:mul, n}: size: foo / 2 (writer multiplies)" do
      yaml = """
      meta:
        id: muln
        endian: le
      seq:
        - id: half_size
          type: u2
        - id: data
          size: half_size / 2
      """

      mod = load(yaml)
      # half_size=2 -> data size 1
      bin = <<2, 0, ?X>>
      m = mod.from_binary(bin)
      assert m.data == "X"
      out = mod.to_binary(%{m | data: "ABCD"})
      # 4 bytes data, half_size = 4 * 2 = 8
      assert out == <<8, 0, ?A, ?B, ?C, ?D>>
    end

    test "{:div, n}: size: foo * 2 (writer divides), raises on non-divisible" do
      yaml = """
      meta:
        id: divn
        endian: le
      seq:
        - id: double_size
          type: u2
        - id: data
          size: double_size * 2
      """

      mod = load(yaml)
      # double_size=1 -> data size 2
      bin = <<1, 0, ?A, ?B>>
      m = mod.from_binary(bin)
      assert m.data == "AB"
      out = mod.to_binary(%{m | data: "ABCD"})
      # 4 bytes data, double_size = 4 / 2 = 2
      assert out == <<2, 0, ?A, ?B, ?C, ?D>>

      # Non-divisible: 3 bytes data -> can't divide by 2
      assert_raise ArgumentError, ~r/non_invertible_controller/, fn ->
        mod.to_binary(%{m | data: "ABC"})
      end
    end

    test "repeat-expr controller auto-update" do
      yaml = """
      meta:
        id: rep_ctrl
        endian: le
      seq:
        - id: count
          type: u2
        - id: items
          type: u4
          repeat: expr
          repeat-expr: count
      """

      mod = load(yaml)
      bin = <<2, 0, 1, 0, 0, 0, 2, 0, 0, 0>>
      m = mod.from_binary(bin)
      assert m.items == [1, 2]
      assert mod.to_binary(m) == bin
      # Grow list — count auto-updates
      out = mod.to_binary(%{m | items: [1, 2, 3, 4]})
      assert out == <<4, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0>>
    end
  end

  describe "conditional (if_expr)" do
    test "field present when condition true; absent when condition false" do
      yaml = """
      meta:
        id: cond_demo
        endian: le
      seq:
        - id: has_extra
          type: u1
        - id: extra
          type: u2
          if: has_extra == 1
      """

      mod = load(yaml)
      bin = <<1, 0x34, 0x12>>
      m = mod.from_binary(bin)
      assert m.extra == 0x1234
      assert mod.to_binary(m) == bin

      # Flip flag to 0 — extra is gone
      out = mod.to_binary(%{m | has_extra: 0, extra: nil})
      assert out == <<0>>
    end
  end

  describe "user types" do
    test "nested type round-trip" do
      yaml = """
      meta:
        id: nested_demo
        endian: le
      seq:
        - id: header
          type: header_t
        - id: body
          type: u2
      types:
        header_t:
          seq:
            - id: magic
              type: u2
            - id: version
              type: u1
      """

      mod = load(yaml)
      bin = <<0x34, 0x12, 7, 0xAB, 0xCD>>
      m = mod.from_binary(bin)
      assert m.header.magic == 0x1234
      assert m.header.version == 7
      assert m.body == 0xCDAB
      assert mod.to_binary(m) == bin
    end
  end

  describe "switch types" do
    test "switch-on round-trip + flip the discriminator" do
      yaml = """
      meta:
        id: switch_demo
        endian: le
      seq:
        - id: kind
          type: u1
        - id: body
          type:
            switch-on: kind
            cases:
              1: u2
              2: u4
      """

      mod = load(yaml)
      bin = <<1, 0x34, 0x12>>
      m = mod.from_binary(bin)
      assert m.kind == 1
      assert m.body == 0x1234
      assert mod.to_binary(m) == bin

      # Switch case: kind=2, body becomes u4
      m2 = %{m | kind: 2, body: 0xDEADBEEF}
      out = mod.to_binary(m2)
      assert out == <<2, 0xEF, 0xBE, 0xAD, 0xDE>>
    end
  end

  describe "process inverses" do
    test "xor: re-xors on write (self-inverse)" do
      yaml = """
      meta:
        id: xor_demo
      seq:
        - id: data
          size: 4
          process: xor(0xAA)
      """

      mod = load(yaml)
      bin = <<0xAA, 0x55, 0xFF, 0x00>>
      m = mod.from_binary(bin)
      # decoded by xor with 0xAA
      assert m.data == <<0x00, 0xFF, 0x55, 0xAA>>
      assert mod.to_binary(m) == bin
    end

    test "rotate_left: writer rotates right" do
      yaml = """
      meta:
        id: rol_demo
      seq:
        - id: data
          size: 2
          process: rol(3)
      """

      mod = load(yaml)
      bin = <<0b10110110, 0b11000011>>
      m = mod.from_binary(bin)
      assert mod.to_binary(m) == bin
    end
  end

  describe "negative paths" do
    test "SJIS encoding raises on write" do
      yaml = """
      meta:
        id: sjis_str
        encoding: SJIS
      seq:
        - id: s
          type: str
          size: 4
      """

      mod = load(yaml)
      # ASCII content, parsed as SJIS (decodes as ASCII passthrough for low bytes)
      m = mod.from_binary(<<?h, ?e, ?l, ?l>>)

      assert_raise ArgumentError, ~r/unsupported write encoding/, fn ->
        mod.to_binary(m)
      end
    end

    test "size_overflow raises when payload exceeds non-controller size" do
      yaml = """
      meta:
        id: fixed_size
      seq:
        - id: data
          size: 4
      """

      mod = load(yaml)
      m = mod.from_binary(<<1, 2, 3, 4>>)
      # Mutate to 8 bytes — declared size is literal 4, no controller — raise.
      assert_raise ArgumentError, ~r/size_overflow/, fn ->
        mod.to_binary(%{m | data: <<1, 2, 3, 4, 5, 6, 7, 8>>})
      end
    end
  end
end
