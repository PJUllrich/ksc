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
end
