defmodule KscTest do
  use ExUnit.Case

  test "compile/1 returns Elixir source code" do
    {:ok, source} = Ksc.compile("reference_code/kaitai_struct_tests/formats/hello_world.ksy")
    assert is_binary(source)
    assert String.contains?(source, "defmodule HelloWorld")
    assert String.contains?(source, "def parse")
  end

  test "compile_and_load/1 returns module atom" do
    ns = "KT#{:erlang.unique_integer([:positive])}"

    {:ok, mod} =
      Ksc.compile_and_load("reference_code/kaitai_struct_tests/formats/hello_world.ksy",
        namespace: ns
      )

    assert is_atom(mod)
    assert function_exported?(mod, :from_file, 1)
    assert function_exported?(mod, :from_binary, 1)
  end

  test "compile_string_and_load/1 works with inline YAML" do
    yaml = """
    meta:
      id: tiny_test
    seq:
      - id: val
        type: u1
    """

    ns = "KST#{:erlang.unique_integer([:positive])}"
    {:ok, mod} = Ksc.compile_string_and_load(yaml, namespace: ns)
    result = mod.from_binary(<<42>>)
    assert result.val == 42
  end

  describe "writer: option" do
    @yaml """
    meta:
      id: writer_gate_test
    seq:
      - id: val
        type: u1
    """

    test "writer: false (default) does NOT emit to_binary" do
      {:ok, source} = Ksc.compile_string(@yaml)
      refute String.contains?(source, "def to_binary")
      refute String.contains?(source, "def to_file")
    end

    test "writer: true emits to_binary and to_file" do
      {:ok, source} = Ksc.compile_string(@yaml, writer: true)
      assert String.contains?(source, "def to_binary")
      assert String.contains?(source, "def to_file")
    end

    test "compile_string_and_load with writer: true exposes to_binary/1" do
      ns = "KWG#{:erlang.unique_integer([:positive])}"
      {:ok, mod} = Ksc.compile_string_and_load(@yaml, namespace: ns, writer: true)
      assert function_exported?(mod, :to_binary, 1)
      assert function_exported?(mod, :to_file, 2)
    end
  end
end
