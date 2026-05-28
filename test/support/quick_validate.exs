formats_dir = "reference_code/kaitai_struct_tests/formats"
fixtures_dir = "reference_code/kaitai_struct_tests/src"
specs_dir = "reference_code/kaitai_struct_tests/spec/ks"

kst_files = Path.wildcard(Path.join(specs_dir, "*.kst")) |> Enum.sort()

run_with_timeout = fn fun, timeout_ms ->
  task = Task.async(fun)

  case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
    {:ok, result} -> result
    nil -> {:error, "timeout"}
  end
end

counts = %{
  compile_ok: 0,
  compile_err: 0,
  load_ok: 0,
  load_err: 0,
  parse_ok: 0,
  parse_err: 0,
  no_bin: 0,
  no_ksy: 0
}

counts =
  Enum.reduce(kst_files, counts, fn kst_path, acc ->
    kst_name = Path.basename(kst_path, ".kst")

    kst =
      try do
        Ksc.Yaml.parse_file(kst_path)
      rescue
        _ -> %{}
      end

    ksy_id = kst["id"] || kst_name
    data_file = kst["data"]
    ksy_path = Path.join(formats_dir, "#{ksy_id}.ksy")

    if not File.exists?(ksy_path) do
      Map.update!(acc, :no_ksy, &(&1 + 1))
    else
      # Compile with 5s timeout
      compile_result =
        run_with_timeout.(
          fn ->
            try do
              {:ok, src} = Ksc.compile(ksy_path)
              {:ok, src}
            rescue
              e -> {:error, Exception.message(e)}
            end
          end,
          5000
        )

      case compile_result do
        {:error, _} ->
          Map.update!(acc, :compile_err, &(&1 + 1))

        {:ok, source} ->
          acc = Map.update!(acc, :compile_ok, &(&1 + 1))

          # Load with 5s timeout
          load_result =
            run_with_timeout.(
              fn ->
                try do
                  modules = Code.compile_string(source)
                  {mod, _} = List.last(modules)
                  {:ok, mod}
                rescue
                  e -> {:error, Exception.message(e)}
                end
              end,
              5000
            )

          case load_result do
            {:error, msg} ->
              IO.puts("LOAD_ERR #{kst_name}: #{String.slice(to_string(msg), 0, 120)}")
              Map.update!(acc, :load_err, &(&1 + 1))

            {:ok, mod} ->
              acc = Map.update!(acc, :load_ok, &(&1 + 1))

              if data_file do
                bin_path = Path.join(fixtures_dir, data_file)

                if File.exists?(bin_path) do
                  # Parse with 5s timeout
                  parse_result =
                    run_with_timeout.(
                      fn ->
                        try do
                          _result = mod.from_file(bin_path)
                          :ok
                        rescue
                          e -> {:error, Exception.message(e)}
                        end
                      end,
                      5000
                    )

                  case parse_result do
                    :ok ->
                      Map.update!(acc, :parse_ok, &(&1 + 1))

                    {:error, msg} ->
                      IO.puts("PARSE_ERR #{kst_name}: #{String.slice(to_string(msg), 0, 120)}")
                      Map.update!(acc, :parse_err, &(&1 + 1))
                  end
                else
                  Map.update!(acc, :no_bin, &(&1 + 1))
                end
              else
                acc
              end
          end
      end
    end
  end)

IO.puts("\n" <> String.duplicate("=", 50))
IO.puts("VALIDATION SUMMARY (#{length(kst_files)} specs)")
IO.puts(String.duplicate("=", 50))
IO.puts("  Compile OK:  #{counts.compile_ok}")
IO.puts("  Compile ERR: #{counts.compile_err}")
IO.puts("  Load OK:     #{counts.load_ok}")
IO.puts("  Load ERR:    #{counts.load_err}")
IO.puts("  Parse OK:    #{counts.parse_ok}")
IO.puts("  Parse ERR:   #{counts.parse_err}")
IO.puts("  No binary:   #{counts.no_bin}")
IO.puts("  No KSY:      #{counts.no_ksy}")
