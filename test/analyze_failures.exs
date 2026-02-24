formats_dir = "reference_code/kaitai_struct_tests/formats"
fixtures_dir = "reference_code/kaitai_struct_tests/src"
specs_dir = "reference_code/kaitai_struct_tests/spec/ks"

kst_files = Path.wildcard(Path.join(specs_dir, "*.kst")) |> Enum.sort()

resolve_path = fn result, path ->
  path = Regex.replace(~r/\.as<[^>]+>/, path, "")
  parts = String.split(path, ".")
  Enum.reduce(parts, result, fn part, acc ->
    case Regex.run(~r/^(.+)\[(\d+)\]$/, part) do
      [_, name, idx] ->
        val = if is_map(acc), do: Map.get(acc, String.to_atom(name)), else: nil
        if is_list(val), do: Enum.at(val, String.to_integer(idx)), else: nil
      nil ->
        cond do
          part == "size" and is_list(acc) -> length(acc)
          part == "length" and is_binary(acc) -> String.length(acc)
          is_map(acc) -> Map.get(acc, String.to_atom(part))
          true -> nil
        end
    end
  end)
end

results = Enum.map(kst_files, fn kst_path ->
  kst_name = Path.basename(kst_path, ".kst")

  kst = try do
    Ksc.Yaml.parse_file(kst_path)
  rescue
    _ -> %{}
  end

  ksy_id = kst["id"] || kst_name
  data_file = kst["data"]
  asserts = kst["asserts"] || []
  ksy_path = Path.join(formats_dir, "#{ksy_id}.ksy")

  cond do
    not File.exists?(ksy_path) ->
      {kst_name, :no_ksy, "KSY not found"}

    true ->
      compile_result = try do
        {:ok, src} = Ksc.compile(ksy_path)
        {:ok, src}
      rescue
        e -> {:error, Exception.message(e)}
      end

      case compile_result do
        {:ok, source} ->
          load_result = try do
            modules = Code.compile_string(source)
            {mod, _} = List.last(modules)
            {:ok, mod}
          rescue
            e -> {:error, Exception.message(e)}
          end

          case load_result do
            {:ok, mod} ->
              if data_file && asserts != [] do
                bin_path = Path.join(fixtures_dir, data_file)
                if File.exists?(bin_path) do
                  parse_result = try do
                    result = mod.from_file(bin_path)
                    {:ok, result}
                  rescue
                    e -> {:error, Exception.message(e)}
                  end

                  case parse_result do
                    {:ok, result} ->
                      failed = Enum.filter(asserts, fn a ->
                        try do
                          _ = resolve_path.(result, a["actual"])
                          false
                        rescue
                          _ -> true
                        end
                      end)

                      if failed == [] do
                        {kst_name, :full_pass, "#{length(asserts)} asserts"}
                      else
                        {kst_name, :assert_fail, "#{length(failed)}/#{length(asserts)} failed"}
                      end

                    {:error, msg} ->
                      {kst_name, :parse_error, String.slice(msg, 0, 100)}
                  end
                else
                  {kst_name, :no_bin, data_file}
                end
              else
                {kst_name, :no_asserts, "compile+load OK"}
              end

            {:error, msg} ->
              {kst_name, :load_error, String.slice(msg, 0, 100)}
          end

        {:error, msg} ->
          {kst_name, :compile_error, String.slice(msg, 0, 100)}
      end
  end
end)

grouped = Enum.group_by(results, fn {_, status, _} -> status end)

IO.puts(String.duplicate("=", 70))
IO.puts("VALIDATION REPORT: #{length(results)} total test specs")
IO.puts(String.duplicate("=", 70))

order = [:full_pass, :no_asserts, :assert_fail, :parse_error, :load_error, :compile_error, :no_ksy, :no_bin]

for status <- order, Map.has_key?(grouped, status) do
  items = grouped[status]
  IO.puts("\n#{String.upcase(to_string(status))} (#{length(items)}):")
  for {name, _, msg} <- Enum.sort(items) do
    IO.puts("  #{name}: #{msg}")
  end
end

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("SUMMARY:")
for status <- order, Map.has_key?(grouped, status) do
  IO.puts("  #{String.pad_trailing(to_string(status), 16)}: #{length(grouped[status])}")
end
IO.puts("  #{String.pad_trailing("TOTAL", 16)}: #{length(results)}")
