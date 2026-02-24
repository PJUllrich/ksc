defmodule ValidateAllTest do
  @moduledoc """
  Attempts to compile and parse every reference .ksy format against its
  .kst test spec, reporting which ones pass, fail to compile, or fail to parse.
  """
  use ExUnit.Case

  @formats_dir "reference_code/kaitai_struct_tests/formats"
  @fixtures_dir "reference_code/kaitai_struct_tests/src"
  @specs_dir "reference_code/kaitai_struct_tests/spec/ks"

  # Get all .kst files
  @kst_files Path.wildcard(Path.join(@specs_dir, "*.kst"))

  for kst_path <- @kst_files do
    kst_name = Path.basename(kst_path, ".kst")

    # Tag tests so we can run them selectively
    @tag :validate_all
    test "#{kst_name}" do
      validate_format(unquote(kst_name))
    end
  end

  defp validate_format(kst_name) do
    kst_path = Path.join(@specs_dir, "#{kst_name}.kst")
    kst = Ksc.Yaml.parse_file(kst_path)

    ksy_id = kst["id"] || kst_name
    data_file = kst["data"]
    asserts = kst["asserts"] || []
    expect_exception = kst["exception"] != nil

    ksy_path = Path.join(@formats_dir, "#{ksy_id}.ksy")

    unless File.exists?(ksy_path) do
      flunk("KSY file not found: #{ksy_path}")
    end

    # Pre-compile opaque type dependencies if needed
    ensure_opaque_types_loaded(ksy_path)

    # Phase 1: Compile
    {compile_result, source} = try do
      {:ok, src} = Ksc.compile(ksy_path)
      {:ok, src}
    rescue
      e -> {:compile_error, Exception.message(e)}
    end

    if compile_result != :ok do
      flunk("Compile failed for #{ksy_id}: #{source}")
    end

    # Phase 2: Load
    load_result = try do
      modules = Code.compile_string(source)
      {mod, _} = List.last(modules)
      {:ok, mod}
    rescue
      e -> {:load_error, Exception.message(e)}
    end

    case load_result do
      {:ok, mod} ->
        if data_file do
          bin_path = Path.join(@fixtures_dir, data_file)
          unless File.exists?(bin_path) do
            flunk("Binary fixture not found: #{bin_path}")
          end

          # Phase 3: Parse
          parse_result = try do
            result = mod.from_file(bin_path)
            {:ok, result}
          rescue
            e -> {:parse_error, Exception.message(e)}
          end

          case parse_result do
            {:ok, result} ->
              # Phase 4: Check assertions
              for assertion <- asserts do
                check_assertion(result, assertion, ksy_id)
              end

            {:parse_error, msg} ->
              if expect_exception and asserts == [] do
                # Exception was expected and no further asserts - test passes
                :ok
              else
                flunk("Parse failed for #{ksy_id}: #{msg}")
              end
          end
        end

      {:load_error, msg} ->
        flunk("Load failed for #{ksy_id}: #{msg}")
    end
  end

  # Pre-compile opaque type dependencies so they're available at parse time
  defp ensure_opaque_types_loaded(ksy_path) do
    ksy = Ksc.Yaml.parse_file(ksy_path)
    meta = Map.get(ksy, "meta", %{}) || %{}
    if Map.get(meta, "ks-opaque-types") == true do
      formats_dir = Path.dirname(ksy_path)
      known_types = Map.keys(Map.get(ksy, "types", %{}))
      seq = Map.get(ksy, "seq", []) || []
      for attr <- seq,
          type = Map.get(attr, "type"),
          is_binary(type),
          type not in known_types,
          type not in ~w(u1 u2 u4 u8 s1 s2 s4 s8 f4 f8 str strz) do
        dep_ksy = Path.join(formats_dir, "#{type}.ksy")
        if File.exists?(dep_ksy) do
          mod_name = type |> Macro.camelize()
          unless Code.ensure_loaded?(String.to_atom("Elixir.#{mod_name}")) do
            try do
              Ksc.compile_and_load(dep_ksy)
            rescue
              _ -> :ok
            end
          end
        end
      end
    end
  end

  defp check_assertion(result, %{"actual" => actual_path, "expected" => expected}, ksy_id) do
    actual_value = try do
      resolve_path(result, actual_path)
    rescue
      e -> {:resolve_error, Exception.message(e)}
    end

    case actual_value do
      {:resolve_error, msg} ->
        flunk("Could not resolve '#{actual_path}' in #{ksy_id}: #{msg}")

      value ->
        expected_value = normalize_expected(expected, ksy_id)
        assert_values_match(value, expected_value, actual_path, ksy_id)
    end
  end

  # Handle assertions without "expected" (just checking it parses)
  defp check_assertion(_result, _assertion, _ksy_id), do: :ok

  defp resolve_path(result, path) when is_binary(path) do
    # Handle array indexing and dot paths
    parts = parse_path(path)
    Enum.reduce(parts, result, fn
      {:field, name}, acc when is_map(acc) ->
        key = String.to_atom(name)
        Map.fetch!(acc, key)

      {:index, idx}, acc when is_list(acc) ->
        Enum.at(acc, idx)

      {:index, idx}, acc when is_binary(acc) ->
        :binary.at(acc, idx)

      {:method, name}, acc when is_map(acc) ->
        # If it's a map, try field access first (these names might be fields)
        key = String.to_atom(name)
        if Map.has_key?(acc, key) do
          Map.fetch!(acc, key)
        else
          apply_method(name, acc)
        end

      {:method, name}, acc ->
        apply_method(name, acc)

      {:cast, _type}, acc ->
        # Type casts like .as<type> - just pass through
        acc
    end)
  end

  defp apply_method("size", acc) when is_list(acc), do: length(acc)
  defp apply_method("size", acc) when is_binary(acc), do: byte_size(acc)
  defp apply_method("size", acc) when is_integer(acc), do: acc
  defp apply_method("length", acc) when is_binary(acc), do: String.length(acc)
  defp apply_method("length", acc) when is_integer(acc), do: acc
  defp apply_method("to_i", acc), do: Ksc.Stream.to_i(acc)
  defp apply_method("to_s", acc) when is_binary(acc), do: acc
  defp apply_method("to_s", acc) when is_integer(acc), do: Integer.to_string(acc)
  defp apply_method("first", acc) when is_list(acc), do: List.first(acc)
  defp apply_method("first", acc) when is_binary(acc), do: :binary.at(acc, 0)
  defp apply_method("last", acc) when is_list(acc), do: List.last(acc)
  defp apply_method("last", acc) when is_binary(acc), do: :binary.at(acc, byte_size(acc) - 1)

  @method_names ~w(size length to_i to_s first last)

  defp parse_path(path) do
    # Remove .as<...> casts
    path = Regex.replace(~r/\.as<[^>]+>/, path, "")

    # Split on dots, handling array indices
    parts = String.split(path, ".")

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, index} ->
      case Regex.run(~r/^(.+)\[(\d+)\]$/, part) do
        [_, name, idx] ->
          [{:field, name}, {:index, String.to_integer(idx)}]
        nil ->
          # First part is always a field; only subsequent parts can be methods
          if index > 0 and part in @method_names do
            [{:method, part}]
          else
            [{:field, part}]
          end
      end
    end)
  end

  defp normalize_expected(val, _ksy_id) when is_integer(val), do: {:int, val}
  defp normalize_expected(val, _ksy_id) when is_float(val), do: {:float, val}
  defp normalize_expected(true, _ksy_id), do: {:bool, true}
  defp normalize_expected(false, _ksy_id), do: {:bool, false}
  defp normalize_expected(nil, _ksy_id), do: {:null, nil}
  defp normalize_expected("null", _ksy_id), do: {:null, nil}

  defp normalize_expected(val, _ksy_id) when is_binary(val) do
    cond do
      # Enum reference: "module::enum_name::value"
      String.contains?(val, "::") ->
        parts = String.split(val, "::")
        enum_val = List.last(parts) |> String.to_atom()
        {:enum, enum_val}

      # Quoted string: '"some text"'
      String.starts_with?(val, "\"") and String.ends_with?(val, "\"") ->
        str = String.slice(val, 1..-2//1)
        # Unescape \uXXXX sequences
        str = Regex.replace(~r/\\u([0-9a-fA-F]{4})/, str, fn _, hex ->
          {cp, _} = Integer.parse(hex, 16)
          <<cp::utf8>>
        end)
        {:string, str}

      # Hex integer literal: '0xffffffff' or '0xffff_ffff'
      Regex.match?(~r/^0x[0-9a-fA-F_]+$/, val) ->
        hex_str = String.trim_leading(val, "0x") |> String.replace("_", "")
        {int_val, _} = Integer.parse(hex_str, 16)
        {:int, int_val}

      # Binary literal: '0b101' or '0b0101_0110'
      Regex.match?(~r/^0b[01_]+$/, val) ->
        bin_str = String.trim_leading(val, "0b") |> String.replace("_", "")
        {int_val, _} = Integer.parse(bin_str, 2)
        {:int, int_val}

      # Array of strings: '["foo", "bar"]' or "['foo', 'bar']"
      Regex.match?(~r/^\[.*["'].*\]/, val) ->
        {:string_array, parse_string_array(val)}

      # Byte array: '[0x73, 0x74, ...]' or '[...].as<bytes>'
      String.starts_with?(val, "[") and (String.contains?(val, "]")) ->
        {:bytes, parse_byte_array(val)}

      # Float with .as<type> suffix: "0.5.as<f4>"
      Regex.match?(~r/^-?[\d.]+\.as<[^>]+>$/, val) ->
        num_str = Regex.replace(~r/\.as<[^>]+>$/, val, "")
        {float_val, _} = Float.parse(num_str)
        {:float, float_val}

      # Boolean strings
      val == "true" -> {:bool, true}
      val == "false" -> {:bool, false}
      val == "null" -> {:null, nil}

      # Simple arithmetic expression: "1 + 4 + 2" -> 7
      Regex.match?(~r/^[\d\s\+\-\*\/]+$/, val) and String.contains?(val, " ") ->
        try do
          {result, _} = Code.eval_string(val)
          if is_integer(result), do: {:int, result}, else: {:float, result}
        rescue
          _ -> {:raw, val}
        end

      # Negative zero: -0 is just 0, -0.0 is -0.0 (Elixir preserves float sign)
      val == "-0" -> {:int, 0}
      val == "-0.0" -> {:float, -0.0}

      true ->
        {:raw, val}
    end
  end

  defp normalize_expected(val, _ksy_id), do: {:raw, val}

  defp parse_string_array(str) do
    # Strip .as<> suffix if present
    str = Regex.replace(~r/\]\.as<[^>]+>$/, str, "]")
    inner = String.slice(str, 1..-2//1) |> String.trim()
    if inner == "" do
      []
    else
      # Parse comma-separated quoted strings (double or single quoted)
      results = Regex.scan(~r/"([^"]*)"/, inner)
      if results == [] do
        # Try single-quoted strings
        Regex.scan(~r/'([^']*)'/, inner)
        |> Enum.map(fn [_, s] -> s end)
      else
        Enum.map(results, fn [_, s] -> s end)
      end
    end
  end

  defp parse_byte_array(str) do
    # Strip trailing # comment from the whole string first
    str = Regex.replace(~r/\]\s*#.*$/, str, "]")
    # Remove .as<type> suffix after the closing bracket
    str = Regex.replace(~r/\]\.as<[^>]+>$/, str, "]")
    inner = String.slice(str, 1..-2//1)
    # Remove .as<bytes> suffix from inner elements if present
    inner = Regex.replace(~r/\.as<[^>]+>/, inner, "")
    inner = String.trim(inner)

    if inner == "" do
      []
    else
      inner
      |> String.split(",")
      |> Enum.map(fn s ->
        s = String.trim(s)
        cond do
          String.starts_with?(s, "0x") ->
            {val, _} = Integer.parse(String.trim_leading(s, "0x"), 16)
            val
          Regex.match?(~r/^-?\d+$/, s) ->
            String.to_integer(s)
          true ->
            # Try evaluating arithmetic expression like "0 + 1"
            try do
              {val, _} = Code.eval_string(s)
              val
            rescue
              _ -> String.to_integer(s)
            end
        end
      end)
    end
  end

  defp assert_values_match(actual, {:int, expected}, path, ksy_id) do
    assert actual == expected,
      "#{ksy_id}: #{path} expected #{expected}, got #{inspect(actual)}"
  end

  defp assert_values_match(actual, {:float, expected}, path, ksy_id) do
    assert_in_delta actual, expected, 0.0001,
      "#{ksy_id}: #{path} expected #{expected}, got #{inspect(actual)}"
  end

  defp assert_values_match(actual, {:bool, expected}, path, ksy_id) do
    assert actual == expected,
      "#{ksy_id}: #{path} expected #{expected}, got #{inspect(actual)}"
  end

  defp assert_values_match(actual, {:null, nil}, path, ksy_id) do
    assert actual == nil,
      "#{ksy_id}: #{path} expected nil, got #{inspect(actual)}"
  end

  defp assert_values_match(actual, {:string, expected}, path, ksy_id) do
    assert actual == expected,
      "#{ksy_id}: #{path} expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp assert_values_match(actual, {:enum, expected}, path, ksy_id) do
    assert actual == expected,
      "#{ksy_id}: #{path} expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp assert_values_match(actual, {:string_array, expected}, path, ksy_id) do
    assert actual == expected,
      "#{ksy_id}: #{path} expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp assert_values_match(actual, {:bytes, expected}, path, ksy_id) do
    actual_bytes = if is_binary(actual), do: :binary.bin_to_list(actual), else: actual
    assert actual_bytes == expected,
      "#{ksy_id}: #{path} expected #{inspect(expected)}, got #{inspect(actual_bytes)}"
  end

  defp assert_values_match(actual, {:raw, expected}, path, ksy_id) when is_binary(expected) do
    # Try to parse as hex integer comparison
    cond do
      String.starts_with?(expected, "0x") ->
        hex_str = String.trim_leading(expected, "0x") |> String.replace("_", "")
        {int_val, _} = Integer.parse(hex_str, 16)
        assert actual == int_val,
          "#{ksy_id}: #{path} expected #{expected} (#{int_val}), got #{inspect(actual)}"

      String.starts_with?(expected, "0b") ->
        bin_str = String.trim_leading(expected, "0b") |> String.replace("_", "")
        {int_val, _} = Integer.parse(bin_str, 2)
        assert actual == int_val,
          "#{ksy_id}: #{path} expected #{expected} (#{int_val}), got #{inspect(actual)}"

      # Float with .as<type> suffix: "0.5.as<f4>"
      Regex.match?(~r/^-?[\d.]+\.as<[^>]+>$/, expected) ->
        num_str = Regex.replace(~r/\.as<[^>]+>$/, expected, "")
        {float_val, _} = Float.parse(num_str)
        assert_in_delta actual, float_val, 0.0001,
          "#{ksy_id}: #{path} expected #{expected}, got #{inspect(actual)}"

      true ->
        assert to_string(actual) == to_string(expected),
          "#{ksy_id}: #{path} expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end

  defp assert_values_match(actual, {:raw, expected}, path, ksy_id) do
    assert to_string(actual) == to_string(expected),
      "#{ksy_id}: #{path} expected #{inspect(expected)}, got #{inspect(actual)}"
  end
end
