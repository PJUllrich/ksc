defmodule ParserTest do
  use ExUnit.Case

  alias Ksc.Parser
  alias Ksc.Format.{ClassSpec, AttrSpec}

  test "parses basic KSY with single field" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/hello_world.ksy")
    assert %ClassSpec{} = spec
    assert spec.id == "hello_world"
    assert length(spec.seq) == 1

    [field] = spec.seq
    assert %AttrSpec{} = field
    assert field.id == "one"
    assert field.type == "u1"
  end

  test "parses meta with endianness" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/integers.ksy")
    assert spec.endian == :le
  end

  test "parses contents fields" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/fixed_contents.ksy")
    [normal, high_bit] = spec.seq
    assert normal.contents == [80, 65, 67, 75, 45, 49]
    assert high_bit.contents == [0xFF, 0xFF]
  end

  test "parses enums" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/enum_0.ksy")
    assert Map.has_key?(spec.enums, "animal")
    animal = spec.enums["animal"]
    assert animal.values[4] == :dog
    assert animal.values[7] == :cat
    assert animal.values[12] == :chicken
  end

  test "parses nested types" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/nested_types.ksy")
    assert Map.has_key?(spec.types, "subtype_a")
    assert Map.has_key?(spec.types, "subtype_b")

    subtype_a = spec.types["subtype_a"]
    assert Map.has_key?(subtype_a.types, "subtype_c")
  end

  test "parses if conditions" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/if_struct.ksy")
    operation = spec.types["operation"]
    [_opcode, arg_tuple, _arg_str] = operation.seq
    assert arg_tuple.if_expr == "opcode == 0x54"
  end

  test "parses repeat expressions" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/repeat_n_struct.ksy")
    [_qty, chunks] = spec.seq
    assert chunks.repeat == "expr"
    assert chunks.repeat_expr == "qty"
  end

  test "parses switch types" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/switch_integers.ksy")
    opcode = spec.types["opcode"]
    [_code, body] = opcode.seq
    assert is_map(body.type)
    assert body.type["switch-on"] == "code"
  end

  test "parses instances" do
    spec = Parser.parse_file("reference_code/kaitai_struct_tests/formats/expr_0.ksy")
    assert Map.has_key?(spec.instances, "must_be_f7")
    assert spec.instances["must_be_f7"].value == "7 + 0xf0"
  end
end
