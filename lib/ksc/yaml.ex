defmodule Ksc.Yaml do
  @moduledoc """
  Minimal YAML parser sufficient for KSY files.
  Handles mappings, sequences, scalars, and quoted strings.
  """

  def parse_file(path) do
    path |> File.read!() |> parse_string()
  end

  def parse_string(string) do
    lines = String.split(string, "\n")
    {result, _rest} = parse_value(lines, 0)
    result
  end

  defp parse_value([], _indent), do: {nil, []}

  defp parse_value(lines, min_indent) do
    lines = drop_empty_and_comments(lines)

    case lines do
      [] ->
        {nil, []}

      [line | _] ->
        indent = count_indent(line)

        if indent < min_indent do
          {nil, lines}
        else
          trimmed = String.trim(line)

          cond do
            String.starts_with?(trimmed, "- ") or trimmed == "-" ->
              parse_sequence(lines, indent)

            String.contains?(trimmed, ": ") or String.ends_with?(trimmed, ":") ->
              parse_mapping(lines, indent)

            true ->
              {parse_scalar(trimmed), tl(lines)}
          end
        end
    end
  end

  defp parse_mapping(lines, base_indent) do
    parse_mapping_entries(lines, base_indent, %{})
  end

  defp parse_mapping_entries(lines, base_indent, acc) do
    lines = drop_empty_and_comments(lines)

    case lines do
      [] ->
        {acc, []}

      [line | rest] ->
        indent = count_indent(line)

        if indent != base_indent do
          {acc, lines}
        else
          trimmed = String.trim(line)

          cond do
            String.contains?(trimmed, ": ") ->
              [key, value_str] = String.split(trimmed, ": ", parts: 2)
              key = unquote_key(key)

              if value_str == "" or value_str == "|" or value_str == ">" do
                {value, remaining} = parse_value(rest, base_indent + 1)
                parse_mapping_entries(remaining, base_indent, Map.put(acc, key, value))
              else
                # Check for multi-line quoted strings (opening quote without closing)
                {value_str, rest} = collect_multiline_string(value_str, rest)
                value = parse_scalar(value_str)
                parse_mapping_entries(rest, base_indent, Map.put(acc, key, value))
              end

            String.ends_with?(trimmed, ":") ->
              key = String.trim_trailing(trimmed, ":") |> unquote_key()
              {value, remaining} = parse_value(rest, base_indent + 1)
              parse_mapping_entries(remaining, base_indent, Map.put(acc, key, value))

            true ->
              {acc, lines}
          end
        end
    end
  end

  defp parse_sequence(lines, base_indent) do
    parse_sequence_items(lines, base_indent, [])
  end

  defp parse_sequence_items(lines, base_indent, acc) do
    lines = drop_empty_and_comments(lines)

    case lines do
      [] ->
        {Enum.reverse(acc), []}

      [line | rest] ->
        indent = count_indent(line)

        if indent != base_indent do
          {Enum.reverse(acc), lines}
        else
          trimmed = String.trim(line)

          cond do
            trimmed == "-" ->
              # Standalone dash, value on next line(s)
              {value, remaining} = parse_value(rest, base_indent + 1)
              parse_sequence_items(remaining, base_indent, [value | acc])

            String.starts_with?(trimmed, "- ") ->
              item_str = String.trim_leading(trimmed, "- ")

              if String.contains?(item_str, ": ") or String.ends_with?(item_str, ":") do
                # Inline mapping start in sequence item
                # Re-parse as mapping with increased indent
                synthetic_indent = indent + 2
                synthetic_line = String.duplicate(" ", synthetic_indent) <> item_str

                # Collect continuation lines that belong to this mapping
                {cont_lines, remaining} = collect_continuation(rest, synthetic_indent)
                all_lines = [synthetic_line | cont_lines]
                {value, _} = parse_mapping(all_lines, synthetic_indent)
                parse_sequence_items(remaining, base_indent, [value | acc])
              else
                value = parse_scalar(item_str)
                parse_sequence_items(rest, base_indent, [value | acc])
              end

            true ->
              {Enum.reverse(acc), lines}
          end
        end
    end
  end

  defp collect_continuation(lines, min_indent) do
    lines = drop_empty_and_comments_peek(lines)

    case lines do
      [] ->
        {[], []}

      [line | rest] ->
        indent = count_indent(line)

        if indent >= min_indent do
          {more, remaining} = collect_continuation(rest, min_indent)
          {[line | more], remaining}
        else
          {[], lines}
        end
    end
  end

  # Collect multi-line quoted strings (e.g., a value starting with " but not ending with ")
  defp collect_multiline_string(value_str, rest) do
    trimmed = String.trim(value_str)
    cond do
      # Double-quoted multi-line
      String.starts_with?(trimmed, "\"") and not ends_with_unescaped_quote?(trimmed) ->
        collect_until_closing_quote(trimmed, rest, "\"")
      # Single-quoted multi-line
      String.starts_with?(trimmed, "'") and String.length(trimmed) > 0 and not (String.ends_with?(trimmed, "'") and String.length(trimmed) > 1) ->
        collect_until_closing_quote(trimmed, rest, "'")
      true ->
        {value_str, rest}
    end
  end

  defp ends_with_unescaped_quote?(str) do
    String.length(str) > 1 and String.ends_with?(str, "\"") and
      not String.ends_with?(str, "\\\"")
  end

  defp collect_until_closing_quote(acc, [], _quote_char), do: {acc, []}
  defp collect_until_closing_quote(acc, [line | rest], quote_char) do
    trimmed = String.trim(line)
    new_acc = acc <> " " <> trimmed
    if String.ends_with?(trimmed, quote_char) do
      {new_acc, rest}
    else
      collect_until_closing_quote(new_acc, rest, quote_char)
    end
  end

  # Like drop_empty_and_comments but doesn't drop lines that have content
  defp drop_empty_and_comments_peek(lines) do
    Enum.drop_while(lines, fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, "#")
    end)
  end

  defp parse_scalar(str) do
    str = String.trim(str)
    # Strip inline comments (but not inside quotes)
    str = strip_inline_comment(str)

    cond do
      str == "true" -> true
      str == "false" -> false
      str == "null" or str == "~" -> nil
      String.starts_with?(str, "'") and String.ends_with?(str, "'") ->
        String.slice(str, 1..-2//1)
      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        String.slice(str, 1..-2//1) |> unescape_string()
      String.starts_with?(str, "0x") ->
        {val, _} = Integer.parse(String.trim_leading(str, "0x"), 16)
        val
      String.starts_with?(str, "0o") ->
        {val, _} = Integer.parse(String.trim_leading(str, "0o"), 8)
        val
      String.starts_with?(str, "[") and String.ends_with?(str, "]") ->
        parse_inline_sequence(str)
      true ->
        case Integer.parse(str) do
          {int, ""} -> int
          {int, rest} ->
            case Float.parse(str) do
              {float, ""} -> float
              _ ->
                if String.trim(rest) == "" do
                  int
                else
                  str
                end
            end
          :error ->
            case Float.parse(str) do
              {float, ""} -> float
              _ -> str
            end
        end
    end
  end

  defp strip_inline_comment(str) do
    if String.starts_with?(str, "'") or String.starts_with?(str, "\"") do
      str
    else
      case String.split(str, " #", parts: 2) do
        [before, _comment] -> String.trim(before)
        [only] -> only
      end
    end
  end

  defp parse_inline_sequence(str) do
    inner = String.slice(str, 1..-2//1) |> String.trim()

    if inner == "" do
      []
    else
      inner
      |> String.split(",")
      |> Enum.map(fn item -> parse_scalar(String.trim(item)) end)
    end
  end

  defp unescape_string(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\\", "\\")
    |> String.replace("\\\"", "\"")
  end

  defp count_indent(line) do
    byte_size(line) - byte_size(String.trim_leading(line, " "))
  end

  defp drop_empty_and_comments(lines) do
    Enum.drop_while(lines, fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, "#") or trimmed == "---"
    end)
  end

  defp unquote_key(key) do
    key = String.trim(key)
    cond do
      String.starts_with?(key, "'") and String.ends_with?(key, "'") ->
        String.slice(key, 1..-2//1)
      String.starts_with?(key, "\"") and String.ends_with?(key, "\"") ->
        String.slice(key, 1..-2//1)
      true ->
        key
    end
  end
end
