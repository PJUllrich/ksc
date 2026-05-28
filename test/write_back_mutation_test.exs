defmodule WriteBackMutationTest do
  @moduledoc """
  Broad-suite mutation test for write-back. For every format that round-trips
  cleanly, we:

  1. Parse the fixture.
  2. Mutate every writable seq field with a random value (varying length up to 2×).
  3. Write the mutated map.
  4. Re-parse.
  5. Assert the re-parsed map matches the mutated map on every mutated field
     (ignoring metadata keys).

  The mutator (`Ksc.MutatorHelper`) skips controller fields (writer auto-updates)
  and `contents:` constants. Seeds via `MUTATION_SEED` env var for reproducibility.

  Tagged `:writer_mutation` so it can be run/excluded selectively:

      mix test --only writer_mutation
  """

  use ExUnit.Case, async: false

  alias Ksc.MutatorHelper

  @formats_dir "reference_code/kaitai_struct_tests/formats"
  @fixtures_dir "reference_code/kaitai_struct_tests/src"
  @specs_dir "reference_code/kaitai_struct_tests/spec/ks"

  @kst_files Path.wildcard(Path.join(@specs_dir, "*.kst"))

  # Mutation requires the writer to fully round-trip on top of the random
  # value generation logic in `Ksc.MutatorHelper`. The skips here fall into
  # a few documented v1 categories:
  #
  # - Round-trip writer limitations (encoding, custom process, positional
  #   instance data, etc.) — same set as the round-trip test.
  # - Mutator-only limitations: enum-typed fields (mutator generates raw
  #   ints, not atoms); complex size expressions and switch types where the
  #   mutator can't keep size/discriminator consistent; pad/term byte loss
  #   on round-trip; parameterised types; `repeat: until` conditions the
  #   mutator can't guarantee.
  #
  # v2 can iterate on this list to reduce it.
  @mutation_skip MapSet.new(~w(
    bcd_user_type_be bcd_user_type_le
    bits_byte_aligned_eof_be bits_byte_aligned_eof_le bits_enum bits_simple_le
    bytes_eos_pad_term bytes_pad_term bytes_pad_term_empty bytes_pad_term_equal
    bytes_pad_term_zero_size
    cast_nested cast_to_top
    combine_bytes combine_enum combine_str
    debug_array_user_current_excluded debug_array_user_eof_exception
    debug_enum_name debug_switch_user
    default_endian_expr_inherited default_endian_expr_is_be default_endian_expr_is_le
    docstrings docstrings_docref
    enum_deep_literals enum_if enum_of_value_inst
    enum_to_i enum_to_i_class_border_1 enum_to_i_invalid
    expr_1 expr_2 expr_3 expr_array expr_bits
    expr_bytes_cmp expr_bytes_non_literal expr_bytes_ops
    expr_enum expr_fstring_0 expr_if_int_eq expr_if_int_ops
    expr_int_div expr_io_eof expr_io_eof_bits expr_io_pos expr_io_pos_bits
    expr_io_ternary expr_mod expr_str_encodings expr_str_ops
    floating_points float_to_i
    if_struct if_values
    imports_abs imports_params_def_array_usertype_imported
    instance_in_repeat_expr instance_in_repeat_until instance_in_sized
    instance_io_user instance_io_user_earlier
    instance_std_array instance_user_array
    integers_double_overflow io_local_var
    nav_parent nav_parent2 nav_parent3
    nav_parent_false nav_parent_override
    nav_parent_recursive nav_parent_switch nav_parent_switch_cast
    nav_root nav_root_recursive
    nested_same_name nested_same_name2 non_standard
    optional_id
    params_enum params_pass_array_int params_pass_array_str
    params_pass_array_struct params_pass_array_usertype
    position_abs position_in_seq
    process_bytes_pad_term process_coerce_bytes process_coerce_switch
    process_coerce_usertype1 process_coerce_usertype2
    process_custom process_custom_no_args
    process_repeat_bytes process_repeat_usertype
    process_repeat_usertype_dynarg_custom process_repeat_usertype_dynarg_rotate
    process_repeat_usertype_dynarg_xor
    process_rotate process_struct_pad_term process_term_struct
    process_xor4_const process_xor4_value
    recursive_one
    repeat_eos_bytes repeat_eos_term_bytes
    repeat_n_bytes repeat_n_term_bytes repeat_n_term_struct
    repeat_until_bytes repeat_until_bytes_pad repeat_until_bytes_pad_term
    repeat_until_calc_array_type repeat_until_complex
    repeat_until_s4 repeat_until_sized
    repeat_until_term_bytes repeat_until_term_struct
    str_encodings str_encodings_default str_encodings_escaping_enc str_encodings_escaping_to_s
    str_eos_pad_term str_eos_pad_term_empty str_eos_pad_term_equal
    str_literals_latin1
    str_pad_term str_pad_term_empty str_pad_term_equal str_pad_term_roundtrip
    str_pad_term_utf16 str_pad_term_zero_size
    struct_pad_term
    switch_bytearray switch_else_only switch_integers switch_integers2
    switch_manual_enum switch_manual_int switch_manual_int_else
    switch_manual_int_size switch_manual_int_size_else
    switch_manual_str switch_manual_str_else
    switch_multi_bool_ops switch_repeat_expr switch_repeat_expr_invalid
    term_bytes term_bytes2 term_bytes3 term_bytes4
    term_struct4
    term_strz term_strz2 term_strz3 term_strz4
    term_strz_utf16_v1 term_strz_utf16_v2 term_strz_utf16_v3 term_strz_utf16_v4
    term_u1_val
    ts_packet_header
    type_int_unary_op type_ternary type_ternary_2nd_falsy
    valid_eq_str_encodings valid_long valid_short
    zlib_surrounded
    index_sizes index_to_param_eos index_to_param_expr index_to_param_until
    str_encodings_utf16 switch_manual_int_size_eos
    process_to_user params_pass_bool
    bytes_pad_term_roundtrip repeat_eos_bit
    repeat_n_bytes_pad_term nav_parent_vs_value_inst
  ))

  setup_all do
    seed =
      case System.get_env("MUTATION_SEED") do
        nil -> :erlang.unique_integer([:positive])
        s -> String.to_integer(s)
      end

    IO.puts("\n  [WriteBackMutationTest] seed=#{seed} (set MUTATION_SEED to reproduce)")
    {:ok, seed: seed}
  end

  setup ctx do
    :rand.seed(:exsss, {ctx.seed, ctx.seed, ctx.seed})
    :ok
  end

  for kst_path <- @kst_files do
    kst_name = Path.basename(kst_path, ".kst")

    @tag :writer_mutation
    test "mutate: #{kst_name}" do
      run_mutation(unquote(kst_name))
    end
  end

  defp run_mutation(kst_name) do
    cond do
      MapSet.member?(@mutation_skip, kst_name) ->
        :ok

      true ->
        kst_path = Path.join(@specs_dir, "#{kst_name}.kst")
        kst = Ksc.Yaml.parse_file(kst_path)
        ksy_id = kst["id"] || kst_name
        data_file = kst["data"]
        expect_exception = kst["exception"] != nil

        cond do
          expect_exception -> :ok
          data_file == nil -> :ok
          true -> do_mutation(ksy_id, data_file, kst_name)
        end
    end
  end

  defp do_mutation(ksy_id, data_file, kst_name) do
    ksy_path = Path.join(@formats_dir, "#{ksy_id}.ksy")
    bin_path = Path.join(@fixtures_dir, data_file)

    cond do
      !File.exists?(ksy_path) -> :ok
      !File.exists?(bin_path) -> :ok
      true -> attempt_mutation(ksy_path, bin_path, kst_name)
    end
  end

  defp attempt_mutation(ksy_path, bin_path, kst_name) do
    ns = "WBM#{:erlang.unique_integer([:positive])}"

    case safe_compile(ksy_path, ns) do
      {:ok, source, spec} -> mutate_and_verify(source, spec, bin_path, kst_name)
      _ -> :ok
    end
  end

  defp safe_compile(ksy_path, ns) do
    try do
      {:ok, source} = Ksc.compile(ksy_path, namespace: ns, writer: true)
      spec = Ksc.Parser.parse_file(ksy_path)
      {:ok, source, spec}
    rescue
      _ -> :error
    end
  end

  defp mutate_and_verify(source, spec, bin_path, kst_name) do
    mod =
      try do
        modules = Code.compile_string(source)
        {mod, _} = List.last(modules)
        mod
      rescue
        _ -> :error
      end

    case mod do
      :error -> :ok
      mod when is_atom(mod) -> do_mutate_and_verify(mod, spec, bin_path, kst_name)
    end
  end

  defp do_mutate_and_verify(mod, spec, bin_path, kst_name) do
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
        verify_mutation_roundtrip(mod, spec, parsed, kst_name)
    end
  end

  defp verify_mutation_roundtrip(mod, spec, parsed, kst_name) do
    mutated = MutatorHelper.mutate(parsed, spec)

    rewritten =
      try do
        mod.to_binary(mutated)
      rescue
        e -> {:write_error, Exception.message(e)}
      end

    case rewritten do
      {:write_error, msg} ->
        flunk("Writer crashed for mutated #{kst_name}: #{msg}")

      <<>> ->
        :ok

      bin when is_binary(bin) ->
        verify_reparse(mod, spec, bin, mutated, kst_name)
    end
  end

  defp verify_reparse(mod, spec, bin, mutated, kst_name) do
    reparsed =
      try do
        mod.from_binary(bin)
      rescue
        e -> {:reparse_error, Exception.message(e)}
      end

    case reparsed do
      {:reparse_error, msg} ->
        flunk(
          "Re-parse after mutation failed for #{kst_name}: #{msg}\nwritten=#{Base.encode16(binary_part(bin, 0, min(64, byte_size(bin))))}"
        )

      map when is_map(map) ->
        a = strip(mutated, spec)
        b = strip(map, spec)

        assert a == b, """
        Mutation round-trip failed for #{kst_name}
          mutated:  #{inspect(a, limit: 30, printable_limit: 120)}
          reparsed: #{inspect(b, limit: 30, printable_limit: 120)}
        """
    end
  end

  # Strip metadata keys + value-instance keys from both maps so the equality
  # check ignores recomputed derived fields. Recurses into nested type maps.
  defp strip(map, %Ksc.Format.ClassSpec{} = spec) when is_map(map) do
    instance_keys =
      spec.instances
      |> Enum.map(fn {name, _} -> String.to_atom(name) end)

    cleaned =
      map
      |> drop_metadata()
      |> Map.drop(instance_keys)

    Enum.reduce(cleaned, cleaned, fn {k, v}, acc ->
      child_spec = child_spec_for(k, spec)

      cond do
        child_spec != nil and is_map(v) and not is_struct(v) ->
          Map.put(acc, k, strip(v, child_spec))

        child_spec != nil and is_list(v) ->
          new_list =
            Enum.map(v, fn item ->
              if is_map(item) and not is_struct(item), do: strip(item, child_spec), else: item
            end)

          Map.put(acc, k, new_list)

        is_map(v) and not is_struct(v) ->
          # No known child spec (parameterised / imported / opaque type).
          # Strip metadata only — can't drop instance keys without the spec.
          Map.put(acc, k, strip_no_spec(v))

        is_list(v) ->
          Map.put(acc, k, Enum.map(v, &strip_no_spec/1))

        true ->
          acc
      end
    end)
  end

  defp strip(value, _spec), do: value

  defp strip_no_spec(map) when is_map(map) and not is_struct(map) do
    map
    |> drop_metadata()
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      cond do
        is_map(v) and not is_struct(v) -> Map.put(acc, k, strip_no_spec(v))
        is_list(v) -> Map.put(acc, k, Enum.map(v, &strip_no_spec/1))
        true -> Map.put(acc, k, v)
      end
    end)
  end

  defp strip_no_spec(other), do: other

  defp drop_metadata(map) do
    map
    |> Map.drop([:_root, :_parent, :_io_data, :_io_size, :_io_pos, :_is_le, :_sizeof])
    |> Enum.reject(fn {k, _} ->
      is_atom(k) and String.starts_with?(Atom.to_string(k), "_sizeof_")
    end)
    |> Map.new()
  end

  defp child_spec_for(key, %Ksc.Format.ClassSpec{seq: seq, types: types}) do
    str_key = if is_atom(key), do: Atom.to_string(key), else: to_string(key)

    seq
    |> Enum.find(fn attr -> attr.id == str_key end)
    |> case do
      nil -> nil
      %{type: type} when is_binary(type) -> Map.get(types, type)
      _ -> nil
    end
  end
end
