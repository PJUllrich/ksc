defmodule ExpressionTest do
  use ExUnit.Case

  alias Ksc.Expression

  describe "literals" do
    test "integer literals" do
      assert Expression.translate("42") == "42"
      assert Expression.translate("0") == "0"
    end

    test "hex literals" do
      assert Expression.translate("0xff") == "0xff"
    end

    test "string literals" do
      assert Expression.translate("\"hello\"") == "\"hello\""
    end

    test "boolean literals" do
      assert Expression.translate("true") == "true"
      assert Expression.translate("false") == "false"
    end
  end

  describe "arithmetic" do
    test "addition" do
      assert Expression.translate("7 + 0xf0") == "(7 + 0xf0)"
    end

    test "string concatenation" do
      assert Expression.translate("\"abc\" + \"123\"") == "\"abc\" <> \"123\""
    end

    test "division" do
      assert Expression.translate("10 / 3") == "Ksc.Stream.floor_div(10, 3)"
    end

    test "modulo" do
      assert Expression.translate("10 % 3") == "Ksc.Stream.floor_mod(10, 3)"
    end
  end

  describe "comparison" do
    test "equality" do
      assert Expression.translate("x == 5") == "(var_x == 5)"
    end

    test "inequality" do
      assert Expression.translate("x != 5") == "(var_x != 5)"
    end
  end

  describe "field references" do
    test "simple field becomes var_ prefixed in parse mode" do
      assert Expression.translate("qty") == "var_qty"
    end

    test "field becomes result[:field] in instance mode" do
      assert Expression.translate_for_instance("qty") == "result[:qty]"
    end

    test "_root becomes root_" do
      assert Expression.translate("_root") == "root_"
    end
  end

  describe "methods" do
    test ".size becomes kaitai_size()" do
      assert Expression.translate("chunks.size") == "Ksc.Stream.kaitai_size(var_chunks)"
    end

    test ".to_i becomes Ksc.Stream.to_i()" do
      assert Expression.translate_for_instance("x.to_i") ==
               "Ksc.Stream.to_i(result[:x], @kaitai_enum_reverse)"
    end

    test ".length becomes kaitai_length()" do
      assert Expression.translate("s.length") == "Ksc.Stream.kaitai_length(var_s)"
    end
  end

  describe "bitwise" do
    test "AND" do
      assert Expression.translate("x & 3") == "Bitwise.band(var_x, 3)"
    end

    test "shift left" do
      assert Expression.translate("x << 2") == "Bitwise.bsl(var_x, 2)"
    end
  end
end
