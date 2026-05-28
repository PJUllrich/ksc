defmodule Ksc do
  @moduledoc """
  Kaitai Struct Compiler for Elixir.

  Compiles .ksy files into Elixir modules that can parse binary data.
  """

  alias Ksc.Parser
  alias Ksc.Compiler.ElixirCompiler

  @doc """
  Compile a .ksy file into an Elixir source code string.

  Options:
    - `:namespace` — module namespace prefix to apply to all generated modules
    - `:writer` — when `true`, also generate `to_binary/1` and `to_file/2` on
      every non-parameterised module. Default `false`.
  """
  def compile(ksy_path, opts \\ []) do
    module_pairs =
      ksy_path
      |> compile_modules(opts)
      |> Enum.reverse()
      |> Enum.uniq_by(fn {name, _} -> name end)
      |> Enum.reverse()

    namespace = opts[:namespace]

    source =
      if namespace do
        all_mod_names = Enum.map(module_pairs, fn {name, _} -> name end)

        Enum.map_join(module_pairs, "\n\n", fn {name, src} ->
          apply_namespace(src, name, all_mod_names, namespace)
        end)
      else
        Enum.map_join(module_pairs, "\n\n", fn {_name, src} -> src end)
      end

    {:ok, source}
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

          sub_enums =
            collect_imported_enums(
              imported_spec.imports || [],
              Path.dirname(ksy_path),
              root_dir,
              seen
            )

          acc |> Map.merge(sub_enums) |> Map.merge(imported_spec.enums)
        else
          acc
        end
      end
    end)
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

  @default_namespace "Ksc.Compiled"

  @doc """
  Compile one or more .ksy files and write each top-level module as a separate .ex file.

  - `input_path` — a single `.ksy` file or a directory containing `.ksy` files
  - `output_dir` — directory where `.ex` files are written (created if it doesn't exist)
  - `opts` — keyword list of options:
    - `:namespace` — module namespace prefix (default: `"Ksc.Compiled"`)
    - `:writer` — when `true`, also generate `to_binary/1` + `to_file/2`. Default `false`.

  Returns `{:ok, [written_file_paths]}` or `{:error, reason}`.
  """
  def compile_to_files(input_path, output_dir, opts \\ []) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)

    ksy_files =
      cond do
        File.dir?(input_path) ->
          Path.wildcard(Path.join(input_path, "**/*.ksy"))

        String.ends_with?(input_path, ".ksy") && File.exists?(input_path) ->
          [input_path]

        true ->
          :error
      end

    case ksy_files do
      :error ->
        {:error, "#{input_path} is not a .ksy file or directory"}

      [] ->
        {:error, "no .ksy files found in #{input_path}"}

      files ->
        File.mkdir_p!(output_dir)

        modules =
          files
          |> Enum.flat_map(&compile_modules(&1, opts))
          |> Enum.uniq_by(fn {mod_name, _source} -> mod_name end)

        all_mod_names = Enum.map(modules, fn {name, _} -> name end)

        written =
          Enum.map(modules, fn {mod_name, source} ->
            source = apply_namespace(source, mod_name, all_mod_names, namespace)
            filename = Macro.underscore(mod_name) <> ".ex"
            path = Path.join(output_dir, filename)
            File.write!(path, source)
            path
          end)

        {:ok, written}
    end
  end

  defp apply_namespace(source, mod_name, all_mod_names, namespace) do
    # Namespace cross-module type references (ModName. -> Namespace.ModName.)
    source =
      Enum.reduce(all_mod_names, source, fn name, src ->
        String.replace(src, "#{name}.", "#{namespace}.#{name}.")
      end)

    # Namespace the top-level defmodule declaration
    String.replace(
      source,
      "defmodule #{mod_name} do",
      "defmodule #{namespace}.#{mod_name} do",
      global: false
    )
  end

  defp compile_modules(ksy_path, opts) do
    spec = Parser.parse_file(ksy_path)
    formats_dir = Path.dirname(ksy_path)

    imported_enums = collect_imported_enums(spec.imports, formats_dir, formats_dir)
    merged_spec = %{spec | enums: Map.merge(imported_enums, spec.enums)}

    import_module_pairs =
      compile_import_modules(
        spec.imports,
        formats_dir,
        formats_dir,
        [],
        MapSet.new(),
        merged_spec.enums,
        opts
      )

    main_source = ElixirCompiler.compile(merged_spec, opts)
    main_mod_name = Ksc.Compiler.Utils.to_module_name(spec.id)

    import_module_pairs ++ [{main_mod_name, main_source}]
  end

  defp compile_import_modules([], _dir, _root_dir, acc, _seen, _parent_enums, _opts),
    do: Enum.reverse(acc)

  defp compile_import_modules([imp | rest], dir, root_dir, acc, seen, parent_enums, opts) do
    {imp_name, resolve_dir} = resolve_import_dir(imp, dir, root_dir)

    if MapSet.member?(seen, imp_name) do
      compile_import_modules(rest, dir, root_dir, acc, seen, parent_enums, opts)
    else
      seen = MapSet.put(seen, imp_name)
      ksy_path = find_import(imp_name, resolve_dir)

      if ksy_path && File.exists?(ksy_path) do
        spec = Parser.parse_file(ksy_path)
        merged_enums = Map.merge(parent_enums, spec.enums)
        spec = %{spec | enums: merged_enums}
        sub_dir = Path.dirname(ksy_path)

        sub_pairs =
          compile_import_modules(spec.imports, sub_dir, root_dir, [], seen, merged_enums, opts)

        source = ElixirCompiler.compile(spec, opts)
        mod_name = Ksc.Compiler.Utils.to_module_name(spec.id)

        compile_import_modules(
          rest,
          dir,
          root_dir,
          [{mod_name, source} | sub_pairs] ++ acc,
          seen,
          parent_enums,
          opts
        )
      else
        compile_import_modules(rest, dir, root_dir, acc, seen, parent_enums, opts)
      end
    end
  end

  @doc """
  Compile a .ksy file and load the resulting module into the VM.
  Returns {:ok, module_atom} on success.

  Options:
    - `:namespace` — module namespace prefix to apply to all generated modules
    - `:writer` — when `true`, also generate `to_binary/1` and `to_file/2`. Default `false`.
  """
  def compile_and_load(ksy_path, opts \\ []) do
    case compile(ksy_path, opts) do
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
  Compile a KSY YAML string into Elixir source code (without loading it).

  Options match `compile/2`.
  """
  def compile_string(yaml_string, opts \\ []) do
    spec = Parser.parse_string(yaml_string)
    source = ElixirCompiler.compile(spec, opts)
    namespace = opts[:namespace]

    source =
      if namespace do
        mod_name = Ksc.Compiler.Utils.to_module_name(spec.id)
        apply_namespace(source, mod_name, [mod_name], namespace)
      else
        source
      end

    {:ok, source}
  end

  @doc """
  Compile a KSY YAML string and load the resulting module.

  Options:
    - `:namespace` — module namespace prefix to apply to the generated module
    - `:writer` — when `true`, also generate `to_binary/1` and `to_file/2`. Default `false`.
  """
  def compile_string_and_load(yaml_string, opts \\ []) do
    {:ok, source} = compile_string(yaml_string, opts)
    modules = Code.compile_string(source)
    {module, _binary} = List.last(modules)
    {:ok, module}
  end
end
