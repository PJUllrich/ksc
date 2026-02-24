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

    # Collect enums from imported modules
    imported_enums = collect_imported_enums(spec.imports, formats_dir)
    # Merge imported enums into main spec
    merged_spec = %{spec | enums: Map.merge(imported_enums, spec.enums)}

    # Compile imported types first, passing merged enums for cross-module enum resolution
    import_sources = compile_imports(spec.imports, formats_dir, [], merged_spec.enums)

    source = ElixirCompiler.compile(merged_spec)
    {:ok, Enum.join(import_sources ++ [source], "\n\n")}
  end

  defp collect_imported_enums(imports, dir) do
    collect_imported_enums(imports, dir, MapSet.new())
  end

  defp collect_imported_enums(imports, dir, seen) do
    Enum.reduce(imports, %{}, fn imp, acc ->
      imp_name = if String.starts_with?(imp, "/"), do: String.trim_leading(imp, "/"), else: imp
      if MapSet.member?(seen, imp_name) do
        acc
      else
        seen = MapSet.put(seen, imp_name)
        ksy_path = find_import(imp_name, dir)
        if ksy_path && File.exists?(ksy_path) do
          imported_spec = Parser.parse_file(ksy_path)
          # Recursively collect from this import's imports
          sub_enums = collect_imported_enums(imported_spec.imports || [], Path.dirname(ksy_path), seen)
          acc |> Map.merge(sub_enums) |> Map.merge(imported_spec.enums)
        else
          acc
        end
      end
    end)
  end

  defp compile_imports(imports, dir, acc, parent_enums) do
    compile_imports(imports, dir, acc, MapSet.new(), parent_enums)
  end

  defp compile_imports([], _dir, acc, _seen, _parent_enums), do: Enum.reverse(acc)
  defp compile_imports([imp | rest], dir, acc, seen, parent_enums) do
    # Handle relative imports (starting with /) vs simple names
    imp_name = if String.starts_with?(imp, "/") do
      String.trim_leading(imp, "/")
    else
      imp
    end

    # Skip circular imports
    if MapSet.member?(seen, imp_name) do
      compile_imports(rest, dir, acc, seen, parent_enums)
    else
      seen = MapSet.put(seen, imp_name)

      # Try to find the .ksy file
      ksy_path = find_import(imp_name, dir)

      if ksy_path && File.exists?(ksy_path) do
        spec = Parser.parse_file(ksy_path)
        # Merge parent enums into imported spec for cross-module enum resolution
        merged_enums = Map.merge(parent_enums, spec.enums)
        spec = %{spec | enums: merged_enums}
        # Recursively compile this import's imports
        sub_dir = Path.dirname(ksy_path)
        sub_imports = compile_imports(spec.imports, sub_dir, [], seen, merged_enums)
        source = ElixirCompiler.compile(spec)
        compile_imports(rest, dir, [source | sub_imports] ++ acc, seen, parent_enums)
      else
        compile_imports(rest, dir, acc, seen, parent_enums)
      end
    end
  end

  defp find_import(name, dir) do
    # Try direct path first
    direct = Path.join(dir, "#{name}.ksy")
    if File.exists?(direct) do
      direct
    else
      # Try ks_path subdirectory (for absolute imports like /common/vlq_base128_le)
      ks_path = Path.join(dir, "ks_path/#{name}.ksy")
      if File.exists?(ks_path) do
        ks_path
      else
        nil
      end
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
