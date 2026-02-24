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

    ksy_path = Path.join(@formats_dir, "#{ksy_id}.ksy")

    unless File.exists?(ksy_path) do
      flunk("KSY file not found: #{ksy_path}")
    end

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
        if data_file && asserts != [] do
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
              flunk("Parse failed for #{ksy_id}: #{msg}")
          end
        end

      {:load_error, msg} ->
        flunk("Load failed for #{ksy_id}: #{msg}")
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

      {:method, "size"}, acc when is_list(acc) ->
        length(acc)

      {:method, "length"}, acc when is_binary(acc) ->
        String.length(acc)

      {:cast, _type}, acc ->
        # Type casts like .as<type> - just pass through
        acc
    end)
  end

  defp parse_path(path) do
    # Remove .as<...> casts
    path = Regex.replace(~r/\.as<[^>]+>/, path, "")

    # Split on dots, handling array indices
    parts = String.split(path, ".")

    Enum.flat_map(parts, fn part ->
      case Regex.run(~r/^(.+)\[(\d+)\]$/, part) do
        [_, name, idx] ->
          [{:field, name}, {:index, String.to_integer(idx)}]
        nil ->
          if part == "size" or part == "length" do
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
  defp normalize_expected("null", _ksy_id), do: {:null, nil}

  defp normalize_expected(val, ksy_id) when is_binary(val) do
    cond do
      # Enum reference: "module::enum_name::value"
      String.contains?(val, "::") ->
        parts = String.split(val, "::")
        enum_val = List.last(parts) |> String.to_atom()
        {:enum, enum_val}

      # Quoted string: '"some text"'
      String.starts_with?(val, "\"") and String.ends_with?(val, "\"") ->
        {:string, String.slice(val, 1..-2//1)}

      # Byte array: '[0x73, 0x74, ...]'
      String.starts_with?(val, "[") ->
        {:bytes, parse_byte_array(val)}

      # Boolean strings
      val == "true" -> {:bool, true}
      val == "false" -> {:bool, false}
      val == "null" -> {:null, nil}

      true ->
        {:raw, val}
    end
  end

  defp normalize_expected(val, _ksy_id), do: {:raw, val}

  defp parse_byte_array(str) do
    inner = String.slice(str, 1..-2//1)
    # Remove .as<bytes> suffix if present
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
          true ->
            String.to_integer(s)
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

  defp assert_values_match(actual, {:bytes, expected}, path, ksy_id) do
    actual_bytes = if is_binary(actual), do: :binary.bin_to_list(actual), else: actual
    assert actual_bytes == expected,
      "#{ksy_id}: #{path} expected #{inspect(expected)}, got #{inspect(actual_bytes)}"
  end

  defp assert_values_match(actual, {:raw, expected}, path, ksy_id) do
    assert to_string(actual) == to_string(expected),
      "#{ksy_id}: #{path} expected #{inspect(expected)}, got #{inspect(actual)}"
  end
end
