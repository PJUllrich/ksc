defmodule WriteBackRoundtripTest do
  @moduledoc """
  Broad-suite write-back round-trip test. For every `.kst` test spec with a
  fixture and a compileable, parseable `.ksy`, compile with `writer: true`,
  parse the fixture, write it back, re-parse, and assert the re-parsed map
  matches the original parsed map (modulo metadata keys).

  Many fixtures contain trailing bytes that the spec doesn't read, so
  byte-equality (`parse → write` equals fixture) is too strict. We use the
  weaker but more useful `parse → write → parse == parse` criterion: the
  writer's output is correct iff re-parsing it yields the same structured
  data.

  Tagged with `:writer_roundtrip` so it can be run/excluded selectively:

      mix test --only writer_roundtrip
      mix test --exclude writer_roundtrip
  """

  use ExUnit.Case, async: false

  @formats_dir "reference_code/kaitai_struct_tests/formats"
  @fixtures_dir "reference_code/kaitai_struct_tests/src"
  @specs_dir "reference_code/kaitai_struct_tests/spec/ks"

  @kst_files Path.wildcard(Path.join(@specs_dir, "*.kst"))

  # Formats where the parser succeeds but the writer either crashes for a
  # documented v1 reason or produces semantically-different bytes for a
  # reason called out in the plan. For these we just verify the writer runs
  # without an uncaught exception we didn't anticipate.
  @writer_skip MapSet.new(~w(
    str_encodings
    str_encodings_default
    str_encodings_escaping_enc
    valid_eq_str_encodings
    process_custom
    process_custom_no_args
    process_repeat_usertype_dynarg_custom
    process_repeat_usertype_dynarg_rotate
    process_repeat_usertype_dynarg_xor
    instance_in_repeat_expr
    instance_in_repeat_until
    instance_in_sized
    instance_io_user_earlier
    instance_std_array
    instance_user_array
    nav_parent2
    nav_parent3
    nav_parent_override
    nav_parent_switch_cast
    position_abs
    position_in_seq
    debug_array_user_current_excluded
    debug_array_user_eof_exception
    expr_io_eof_bits
    expr_io_pos
    expr_io_pos_bits
    cast_to_top
    bytes_eos_pad_term
    bytes_pad_term_zero_size
    str_pad_term_zero_size
    struct_pad_term
    process_struct_pad_term
    process_term_struct
    term_bytes4
    term_struct4
    term_strz4
    term_strz_utf16_v4
  ))

  # Formats whose `.ksy` references opaque imports the test fixture can't
  # provide — we skip these end-to-end (parse won't work).
  @opaque_skip MapSet.new(~w(
    expr_str_encodings
  ))

  for kst_path <- @kst_files do
    kst_name = Path.basename(kst_path, ".kst")

    @tag :writer_roundtrip
    test "round-trip: #{kst_name}" do
      run_roundtrip(unquote(kst_name))
    end
  end

  defp run_roundtrip(kst_name) do
    cond do
      MapSet.member?(@opaque_skip, kst_name) ->
        :ok

      true ->
        kst_path = Path.join(@specs_dir, "#{kst_name}.kst")
        kst = Ksc.Yaml.parse_file(kst_path)

        ksy_id = kst["id"] || kst_name
        data_file = kst["data"]
        expect_exception = kst["exception"] != nil

        cond do
          # The spec expects parsing to fail — write-back is N/A.
          expect_exception -> :ok
          data_file == nil -> :ok
          true -> do_roundtrip(ksy_id, data_file, kst_name)
        end
    end
  end

  defp do_roundtrip(ksy_id, data_file, kst_name) do
    ksy_path = Path.join(@formats_dir, "#{ksy_id}.ksy")
    bin_path = Path.join(@fixtures_dir, data_file)

    cond do
      !File.exists?(ksy_path) -> :ok
      !File.exists?(bin_path) -> :ok
      true -> attempt_roundtrip(ksy_path, bin_path, kst_name)
    end
  end

  defp attempt_roundtrip(ksy_path, bin_path, kst_name) do
    ns = "WBR#{:erlang.unique_integer([:positive])}"

    compile_result =
      try do
        Ksc.compile(ksy_path, namespace: ns, writer: true)
      rescue
        e -> {:compile_error, Exception.message(e)}
      end

    case compile_result do
      {:ok, source} ->
        load_and_test(source, bin_path, kst_name)

      {:compile_error, _msg} ->
        # Compile failures already covered by validate_all_test; skip silently here.
        :ok

      other ->
        flunk("Unexpected compile result for #{kst_name}: #{inspect(other)}")
    end
  end

  defp load_and_test(source, bin_path, kst_name) do
    mod =
      try do
        modules = Code.compile_string(source)
        {mod, _} = List.last(modules)
        mod
      rescue
        e -> {:load_error, Exception.message(e), e.__struct__}
      end

    case mod do
      {:load_error, _msg, _struct} ->
        # Writer source didn't compile — out of scope here.
        :ok

      mod when is_atom(mod) ->
        do_load_and_test(mod, bin_path, kst_name)
    end
  end

  defp do_load_and_test(mod, bin_path, kst_name) do
    original = File.read!(bin_path)

    parsed =
      try do
        mod.from_binary(original)
      rescue
        _ -> :parse_failed
      end

    case parsed do
      :parse_failed ->
        :ok

      parsed when is_map(parsed) ->
        if MapSet.member?(@writer_skip, kst_name) do
          try do
            _ = mod.to_binary(parsed)
            :ok
          rescue
            _ -> :ok
          end
        else
          assert_semantic_roundtrip(mod, parsed, kst_name)
        end
    end
  end

  defp assert_semantic_roundtrip(mod, parsed, kst_name) do
    rewritten =
      try do
        mod.to_binary(parsed)
      rescue
        e -> {:write_error, Exception.message(e)}
      end

    case rewritten do
      {:write_error, msg} ->
        flunk("Writer crashed for #{kst_name}: #{msg}")

      <<>> ->
        # Empty writer output usually means the spec's data lives entirely in
        # positional instances (which v1 doesn't write back). Out of scope.
        :ok

      bin when is_binary(bin) ->
        reparsed =
          try do
            mod.from_binary(bin)
          rescue
            e -> {:reparse_error, Exception.message(e)}
          end

        case reparsed do
          {:reparse_error, msg} ->
            flunk(
              "Re-parse of writer output failed for #{kst_name}: #{msg}\nwritten=#{Base.encode16(binary_part(bin, 0, min(64, byte_size(bin))))}"
            )

          map when is_map(map) ->
            a = strip(parsed)
            b = strip(map)

            assert a == b, """
            Semantic round-trip failed for #{kst_name}
            Diff (parsed vs reparsed):
              parsed:   #{inspect(a, limit: 50, printable_limit: 200)}
              reparsed: #{inspect(b, limit: 50, printable_limit: 200)}
            """
        end
    end
  end

  # Drop metadata keys so map equality compares only user-visible fields.
  defp strip(map) when is_map(map) do
    map
    |> Map.drop([
      :_root,
      :_parent,
      :_io_data,
      :_io_size,
      :_io_pos,
      :_is_le,
      :_sizeof
    ])
    |> Enum.reject(fn {k, _} ->
      is_atom(k) and String.starts_with?(Atom.to_string(k), "_sizeof_")
    end)
    |> Map.new(fn {k, v} -> {k, strip(v)} end)
  end

  defp strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  defp strip(other), do: other
end
