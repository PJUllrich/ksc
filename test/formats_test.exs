defmodule FormatsTest do
  use ExUnit.Case

  @formats_dir "reference_code/kaitai_struct_tests/formats"
  @fixtures_dir "reference_code/kaitai_struct_tests/src"

  defp compile_and_parse(ksy_name, bin_name) do
    ns = "FT#{:erlang.unique_integer([:positive])}"
    {:ok, mod} = Ksc.compile_and_load(Path.join(@formats_dir, "#{ksy_name}.ksy"), namespace: ns)
    mod.from_file(Path.join(@fixtures_dir, bin_name))
  end

  # ── Phase 1: Basic types ──────────────────────────────────────────────

  describe "hello_world" do
    test "parses single u1 field" do
      result = compile_and_parse("hello_world", "fixed_struct.bin")
      assert result.one == 0x50
    end
  end

  describe "fixed_contents" do
    test "validates magic byte sequences" do
      result = compile_and_parse("fixed_contents", "fixed_struct.bin")
      assert result.normal == <<80, 65, 67, 75, 45, 49>>
      assert result.high_bit_8 == <<255, 255>>
    end
  end

  describe "integers" do
    setup do
      %{result: compile_and_parse("integers", "fixed_struct.bin")}
    end

    test "unsigned integers", %{result: r} do
      assert r.uint8 == 255
      assert r.uint16 == 65535
      assert r.uint32 == 4_294_967_295
      assert r.uint64 == 18_446_744_073_709_551_615
    end

    test "signed integers", %{result: r} do
      assert r.sint8 == -1
      assert r.sint16 == -1
      assert r.sint32 == -1
      assert r.sint64 == -1
    end

    test "explicit little-endian", %{result: r} do
      assert r.uint16le == 66
      assert r.uint32le == 66
      assert r.uint64le == 66
      assert r.sint16le == -66
      assert r.sint32le == -66
      assert r.sint64le == -66
    end

    test "explicit big-endian", %{result: r} do
      assert r.uint16be == 66
      assert r.uint32be == 66
      assert r.uint64be == 66
      assert r.sint16be == -66
      assert r.sint32be == -66
      assert r.sint64be == -66
    end
  end

  # ── Phase 2: Enums, nested types, strings, byte padding ──────────────

  describe "enum_0" do
    test "resolves enum values" do
      result = compile_and_parse("enum_0", "enum_0.bin")
      assert result.pet_1 == :cat
      assert result.pet_2 == :chicken
    end
  end

  describe "nested_types" do
    test "parses nested type hierarchy" do
      result = compile_and_parse("nested_types", "fixed_struct.bin")
      assert result.one.typed_at_root.value_b == 80
      assert result.one.typed_here.value_c == 65
      assert result.two.value_b == 67
    end
  end

  describe "str_encodings" do
    test "parses ASCII and UTF-8 strings" do
      result = compile_and_parse("str_encodings", "str_encodings.bin")
      assert result.str1 == "Some ASCII"
      assert result.str2 == "こんにちは"
    end
  end

  describe "bytes_pad_term" do
    setup do
      %{result: compile_and_parse("bytes_pad_term", "str_pad_term.bin")}
    end

    test "pad-right strips trailing padding", %{result: r} do
      assert :binary.bin_to_list(r.str_pad) == [0x73, 0x74, 0x72, 0x31]
    end

    test "terminator without include", %{result: r} do
      assert :binary.bin_to_list(r.str_term) == [0x73, 0x74, 0x72, 0x32, 0x66, 0x6F, 0x6F]
    end

    test "terminator with pad-right", %{result: r} do
      expected = [0x73, 0x74, 0x72, 0x2B, 0x2B, 0x2B, 0x33, 0x62, 0x61, 0x72, 0x2B, 0x2B, 0x2B]
      assert :binary.bin_to_list(r.str_term_and_pad) == expected
    end

    test "terminator with include", %{result: r} do
      expected = [0x73, 0x74, 0x72, 0x34, 0x62, 0x61, 0x7A, 0x40]
      assert :binary.bin_to_list(r.str_term_include) == expected
    end
  end

  # ── Phase 3: Conditionals, repetition, expressions ────────────────────

  describe "if_struct" do
    setup do
      %{result: compile_and_parse("if_struct", "if_struct.bin")}
    end

    test "op1: string opcode", %{result: r} do
      assert r.op1.opcode == 0x53
      assert r.op1.arg_tuple == nil
      assert r.op1.arg_str.str == "foo"
    end

    test "op2: tuple opcode", %{result: r} do
      assert r.op2.opcode == 0x54
      assert r.op2.arg_tuple.num1 == 0x42
      assert r.op2.arg_tuple.num2 == 0x43
      assert r.op2.arg_str == nil
    end

    test "op3: string opcode", %{result: r} do
      assert r.op3.opcode == 0x53
      assert r.op3.arg_tuple == nil
      assert r.op3.arg_str.str == "bar"
    end
  end

  describe "repeat_n_struct" do
    test "parses N repeated chunks" do
      result = compile_and_parse("repeat_n_struct", "repeat_n_struct.bin")
      assert length(result.chunks) == 2
      assert Enum.at(result.chunks, 0).offset == 0x10
      assert Enum.at(result.chunks, 0).len == 0x2078
      assert Enum.at(result.chunks, 1).offset == 0x2088
      assert Enum.at(result.chunks, 1).len == 0x0F
    end
  end

  describe "repeat_eos_struct" do
    test "parses chunks until end of stream" do
      result = compile_and_parse("repeat_eos_struct", "repeat_eos_struct.bin")
      assert length(result.chunks) == 2
      assert Enum.at(result.chunks, 0).offset == 0
      assert Enum.at(result.chunks, 0).len == 0x42
      assert Enum.at(result.chunks, 1).offset == 0x42
      assert Enum.at(result.chunks, 1).len == 0x815
    end
  end

  describe "expr_0" do
    test "computes value instances" do
      result = compile_and_parse("expr_0", "str_encodings.bin")
      assert result.must_be_f7 == 0xF7
      assert result.must_be_abc123 == "abc123"
    end
  end

  # ── Phase 4: Switch types ─────────────────────────────────────────────

  describe "switch_integers" do
    setup do
      %{result: compile_and_parse("switch_integers", "switch_integers.bin")}
    end

    test "parses correct number of opcodes", %{result: r} do
      assert length(r.opcodes) == 4
    end

    test "u1 case", %{result: r} do
      assert Enum.at(r.opcodes, 0).code == 1
      assert Enum.at(r.opcodes, 0).body == 7
    end

    test "u2 case", %{result: r} do
      assert Enum.at(r.opcodes, 1).code == 2
      assert Enum.at(r.opcodes, 1).body == 0x4040
    end

    test "u4 case", %{result: r} do
      assert Enum.at(r.opcodes, 2).code == 4
      assert Enum.at(r.opcodes, 2).body == 4919
    end

    test "u8 case", %{result: r} do
      assert Enum.at(r.opcodes, 3).code == 8
      assert Enum.at(r.opcodes, 3).body == 4919
    end
  end

  describe "switch_manual_int" do
    setup do
      %{result: compile_and_parse("switch_manual_int", "switch_opcodes.bin")}
    end

    test "parses correct number of opcodes", %{result: r} do
      assert length(r.opcodes) == 4
    end

    test "strval case (foobar)", %{result: r} do
      assert Enum.at(r.opcodes, 0).code == 83
      assert Enum.at(r.opcodes, 0).body.value == "foobar"
    end

    test "intval case (0x42)", %{result: r} do
      assert Enum.at(r.opcodes, 1).code == 73
      assert Enum.at(r.opcodes, 1).body.value == 0x42
    end

    test "intval case (0x37)", %{result: r} do
      assert Enum.at(r.opcodes, 2).code == 73
      assert Enum.at(r.opcodes, 2).body.value == 0x37
    end

    test "strval case (empty)", %{result: r} do
      assert Enum.at(r.opcodes, 3).code == 83
      assert Enum.at(r.opcodes, 3).body.value == ""
    end
  end
end
