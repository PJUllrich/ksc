defmodule Ksc do
  @moduledoc """
  Kaitai Struct Compiler for Elixir.

  Compiles .ksy files into Elixir modules that can parse binary data.
  """

  alias Ksc.Parser
  alias Ksc.Compiler.ElixirCompiler

  @doc """
  Compile a .ksy file into an Elixir source code string.
  """
  def compile(ksy_path) do
    spec = Parser.parse_file(ksy_path)
    {:ok, ElixirCompiler.compile(spec)}
  end

  @doc """
  Compile a .ksy file and load the resulting module into the VM.
  Returns {:ok, module_atom} on success.
  """
  def compile_and_load(ksy_path) do
    case compile(ksy_path) do
      {:ok, source} ->
        modules = Code.compile_string(source)
        # The last module compiled is the top-level one
        {module, _binary} = List.last(modules)
        {:ok, module}

      error ->
        error
    end
  end

  @doc """
  Compile a KSY YAML string and load the resulting module.
  """
  def compile_string_and_load(yaml_string) do
    spec = Parser.parse_string(yaml_string)
    source = ElixirCompiler.compile(spec)
    modules = Code.compile_string(source)
    {module, _binary} = List.last(modules)
    {:ok, module}
  end
end
