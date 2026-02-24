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
    imported_enums = collect_imported_enums(spec.imports, formats_dir, formats_dir)
    # Merge imported enums into main spec
    merged_spec = %{spec | enums: Map.merge(imported_enums, spec.enums)}

    # Compile imported types first, passing merged enums for cross-module enum resolution
    import_sources = compile_imports(spec.imports, formats_dir, formats_dir, [], merged_spec.enums)

    source = ElixirCompiler.compile(merged_spec)
    {:ok, Enum.join(import_sources ++ [source], "\n\n")}
  end

  defp collect_imported_enums(imports, dir, root_dir) do
    collect_imported_enums(imports, dir, root_dir, MapSet.new())
  end

  defp collect_imported_enums(imports, dir, root_dir, seen) do
    Enum.reduce(imports, %{}, fn imp, acc ->
      {imp_name, resolve_dir} = resolve_import_dir(imp, dir, root_dir)
      if MapSet.member?(seen, imp_name) do
        acc
      else
        seen = MapSet.put(seen, imp_name)
        ksy_path = find_import(imp_name, resolve_dir)
        if ksy_path && File.exists?(ksy_path) do
          imported_spec = Parser.parse_file(ksy_path)
          sub_enums = collect_imported_enums(imported_spec.imports || [], Path.dirname(ksy_path), root_dir, seen)
          acc |> Map.merge(sub_enums) |> Map.merge(imported_spec.enums)
        else
          acc
        end
      end
    end)
  end

  defp compile_imports(imports, dir, root_dir, acc, parent_enums) do
    compile_imports(imports, dir, root_dir, acc, MapSet.new(), parent_enums)
  end

  defp compile_imports([], _dir, _root_dir, acc, _seen, _parent_enums), do: Enum.reverse(acc)
  defp compile_imports([imp | rest], dir, root_dir, acc, seen, parent_enums) do
    {imp_name, resolve_dir} = resolve_import_dir(imp, dir, root_dir)

    if MapSet.member?(seen, imp_name) do
      compile_imports(rest, dir, root_dir, acc, seen, parent_enums)
    else
      seen = MapSet.put(seen, imp_name)
      ksy_path = find_import(imp_name, resolve_dir)

      if ksy_path && File.exists?(ksy_path) do
        spec = Parser.parse_file(ksy_path)
        merged_enums = Map.merge(parent_enums, spec.enums)
        spec = %{spec | enums: merged_enums}
        sub_dir = Path.dirname(ksy_path)
        sub_imports = compile_imports(spec.imports, sub_dir, root_dir, [], seen, merged_enums)
        source = ElixirCompiler.compile(spec)
        compile_imports(rest, dir, root_dir, [source | sub_imports] ++ acc, seen, parent_enums)
      else
        compile_imports(rest, dir, root_dir, acc, seen, parent_enums)
      end
    end
  end

  # Absolute imports (starting with /) resolve from root_dir; relative from current dir
  defp resolve_import_dir(imp, dir, root_dir) do
    if String.starts_with?(imp, "/") do
      {String.trim_leading(imp, "/"), root_dir}
    else
      {imp, dir}
    end
  end

  defp find_import(name, dir) do
    direct = Path.join(dir, "#{name}.ksy")
    if File.exists?(direct) do
      direct
    else
      ks_path = Path.join(dir, "ks_path/#{name}.ksy")
      if File.exists?(ks_path), do: ks_path, else: nil
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
