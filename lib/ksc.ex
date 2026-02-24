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
    formats_dir = Path.dirname(ksy_path)

    # Compile imported types first
    import_sources = compile_imports(spec.imports, formats_dir, [])

    source = ElixirCompiler.compile(spec)
    {:ok, Enum.join(import_sources ++ [source], "\n\n")}
  end

  defp compile_imports(imports, dir, acc) do
    compile_imports(imports, dir, acc, MapSet.new())
  end

  defp compile_imports([], _dir, acc, _seen), do: Enum.reverse(acc)
  defp compile_imports([imp | rest], dir, acc, seen) do
    # Handle relative imports (starting with /) vs simple names
    imp_name = if String.starts_with?(imp, "/") do
      String.trim_leading(imp, "/")
    else
      imp
    end

    # Skip circular imports
    if MapSet.member?(seen, imp_name) do
      compile_imports(rest, dir, acc, seen)
    else
      seen = MapSet.put(seen, imp_name)

      # Try to find the .ksy file
      ksy_path = find_import(imp_name, dir)

      if ksy_path && File.exists?(ksy_path) do
        spec = Parser.parse_file(ksy_path)
        # Recursively compile this import's imports
        sub_dir = Path.dirname(ksy_path)
        sub_imports = compile_imports(spec.imports, sub_dir, [], seen)
        source = ElixirCompiler.compile(spec)
        compile_imports(rest, dir, [source | sub_imports] ++ acc, seen)
      else
        compile_imports(rest, dir, acc, seen)
      end
    end
  end

  defp find_import(name, dir) do
    # Try direct path first
    direct = Path.join(dir, "#{name}.ksy")
    if File.exists?(direct) do
      direct
    else
      # Try nested path (e.g., "common/vlq_base128_le")
      nested = Path.join(dir, "#{name}.ksy")
      if File.exists?(nested), do: nested, else: nil
    end
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
