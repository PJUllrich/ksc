defmodule Ksc.Expression do
  @moduledoc """
  Translates KSY expression language to Elixir code strings.
  Supports :parse mode (var_field), :instance mode (result[:field]), :repeat_until mode.
  """

  def translate(expr) when is_binary(expr) do
    String.trim(expr) |> do_translate(:parse)
  end

  def translate_for_instance(expr) when is_binary(expr) do
    String.trim(expr) |> do_translate(:instance)
  end

  def translate_for_repeat_until(expr) when is_binary(expr) do
    String.trim(expr) |> do_translate(:repeat_until)
  end

  defp do_translate(expr, mode) do
    cond do
      expr == "" -> "nil"
      expr == "true" -> "true"
      expr == "false" -> "false"
      expr == "null" -> "nil"

      # Ternary: cond ? a : b
      has_ternary?(expr) ->
        translate_ternary(expr, mode)

      # Boolean operators
      has_binary_op?(expr, [" or ", " and "]) ->
        translate_binary_op(expr, [" or ", " and "], mode)

      # Comparison
      has_binary_op?(expr, [" == ", " != ", " <= ", " >= ", " < ", " > "]) ->
        translate_comparison(expr, mode)

      # Bitwise
      has_binary_op?(expr, [" | ", " & ", " ^ "]) ->
        translate_bitwise(expr, mode)

      # Shift
      has_binary_op?(expr, [" << ", " >> "]) ->
        translate_shift(expr, mode)

      # Additive
      has_additive_op?(expr) ->
        translate_additive(expr, mode)

      # Multiplicative
      has_binary_op?(expr, [" * ", " / ", " % "]) ->
        translate_multiplicative(expr, mode)

      # Unary not
      String.starts_with?(expr, "not ") ->
        inner = String.slice(expr, 4..-1//1) |> String.trim()
        "not (#{do_translate(inner, mode)})"

      # Unary negation (minus)
      String.starts_with?(expr, "-") and String.length(expr) > 1 ->
        inner = String.slice(expr, 1..-1//1) |> String.trim()
        if is_integer_literal?(inner) or is_float_literal?(inner) do
          "-#{inner}"
        else
          "-(#{do_translate(inner, mode)})"
        end

      # Unary bitwise complement
      String.starts_with?(expr, "~") ->
        inner = String.slice(expr, 1..-1//1) |> String.trim()
        "Bitwise.bnot(#{do_translate(inner, mode)})"

      # Parenthesized
      String.starts_with?(expr, "(") and matching_paren_at_end?(expr) ->
        inner = String.slice(expr, 1..-2//1)
        "(#{do_translate(inner, mode)})"

      # f-string (formatted string): f"abc={expr}" -> "abc=#{expr}"
      String.starts_with?(expr, "f\"") and String.ends_with?(expr, "\"") ->
        translate_fstring(expr, mode)

      # String literal
      String.starts_with?(expr, "\"") and String.ends_with?(expr, "\"") ->
        expr

      # Hex literal
      String.starts_with?(expr, "0x") -> expr
      String.starts_with?(expr, "0o") -> expr

      # Integer literal
      is_integer_literal?(expr) -> expr

      # Float literal
      is_float_literal?(expr) -> expr

      # Byte array literal
      String.starts_with?(expr, "[") and String.ends_with?(expr, "]") ->
        translate_byte_array(expr, mode)

      # _io.pos and _io.size - special handling
      expr == "_io.pos" ->
        "io_pos"
      expr == "_io.size" ->
        "io_size"
      expr == "_io.eof" ->
        "(io_pos >= io_size)"

      # _is_le special variable for default_endian_expr
      expr == "_is_le" ->
        "var__is_le"

      # sizeof<Type> - compile-time type size
      String.starts_with?(expr, "sizeof<") and String.ends_with?(expr, ">") ->
        type_name = String.slice(expr, 7..-2//1)
        mod_name = type_name |> String.split("::") |> Enum.map(fn part ->
          part |> String.split("_") |> Enum.map(&String.capitalize/1) |> Enum.join()
        end) |> Enum.join(".")
        "#{mod_name}.__sizeof__()"

      # Method/field access: expr.method
      has_dot_access?(expr) ->
        translate_dot_access(expr, mode)

      # Array index: expr[idx]
      has_array_access?(expr) ->
        translate_array_access(expr, mode)

      # Enum reference: enum_name::value -> :value
      String.contains?(expr, "::") ->
        parts = String.split(expr, "::")
        value = List.last(parts) |> String.trim()
        ":#{value}"

      # Simple identifier
      Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, expr) ->
        translate_identifier(expr, mode)

      true ->
        expr
    end
  end

  defp matching_paren_at_end?(expr) do
    chars = String.graphemes(expr)
    if hd(chars) != "(" or List.last(chars) != ")" do
      false
    else
      # Walk from position 1, tracking depth. If depth reaches 0 before the last char,
      # the opening paren doesn't match the closing one.
      inner = Enum.slice(chars, 1..-2//1)
      {balanced, _} = Enum.reduce_while(inner, {true, 1}, fn ch, {_, depth} ->
        new_depth = case ch do
          "(" -> depth + 1
          ")" -> depth - 1
          _ -> depth
        end
        if new_depth == 0 do
          {:halt, {false, 0}}
        else
          {:cont, {true, new_depth}}
        end
      end)
      balanced
    end
  end

  defp translate_fstring(expr, mode) do
    # f"text{expr}text" -> "text#{translated_expr}text"
    # Strip leading f and outer quotes
    inner = String.slice(expr, 2..-2//1)
    # Escape backslashes so \n stays literal in Elixir string
    inner = String.replace(inner, "\\", "\\\\")
    # Replace {expr} with Elixir interpolation #{translated_expr}
    result = Regex.replace(~r/\{([^}]+)\}/, inner, fn _, ksy_expr ->
      # Handle single-quoted strings inside interpolation -> just the string value
      ksy_expr = String.trim(ksy_expr)
      if String.starts_with?(ksy_expr, "'") and String.ends_with?(ksy_expr, "'") do
        content = String.slice(ksy_expr, 1..-2//1)
        "\#{\"" <> content <> "\"}"
      else
        translated = do_translate(ksy_expr, mode)
        "\#{to_string(" <> translated <> ")}"
      end
    end)
    "\"" <> result <> "\""
  end

  defp translate_byte_array(expr, mode) do
    inner = String.slice(expr, 1..-2//1) |> String.trim()
    if inner == "" do
      "<<>>"
    else
      raw_items = String.split(inner, ",") |> Enum.map(&String.trim/1)

      # Detect if this should be a list (non-byte elements) or a binary (byte array)
      has_strings = Enum.any?(raw_items, &(String.starts_with?(&1, "\"") or String.starts_with?(&1, "'")))
      has_floats = Enum.any?(raw_items, &String.contains?(&1, "."))
      has_large_ints = Enum.any?(raw_items, fn s ->
        case Integer.parse(s) do
          {n, ""} -> n > 255 or n < 0
          _ -> false
        end
      end)
      # If any item is a non-literal (identifier, expression), use a list
      has_non_literals = Enum.any?(raw_items, fn s ->
        not (is_integer_literal?(s) or String.starts_with?(s, "0x") or String.starts_with?(s, "0o") or
             String.starts_with?(s, "\"") or String.starts_with?(s, "'"))
      end)

      items = Enum.map(raw_items, fn s -> do_translate(s, mode) end)

      if has_strings or has_floats or has_large_ints or has_non_literals do
        # Use Elixir list
        "[#{Enum.join(items, ", ")}]"
      else
        "<<#{Enum.join(items, ", ")}>>"
      end
    end
  end

  defp has_ternary?(expr), do: find_operator_outside_groups(expr, " ? ") != nil

  defp translate_ternary(expr, mode) do
    case find_operator_outside_groups(expr, " ? ") do
      nil -> expr
      pos ->
        cond_part = String.slice(expr, 0, pos) |> String.trim()
        rest = String.slice(expr, (pos + 3)..-1//1) |> String.trim()

        case find_operator_outside_groups(rest, " : ") do
          nil -> expr
          colon_pos ->
            true_part = String.slice(rest, 0, colon_pos) |> String.trim()
            false_part = String.slice(rest, (colon_pos + 3)..-1//1) |> String.trim()
            "if(#{do_translate(cond_part, mode)}, do: #{do_translate(true_part, mode)}, else: #{do_translate(false_part, mode)})"
        end
    end
  end

  defp has_binary_op?(expr, ops) do
    Enum.any?(ops, &(find_operator_outside_groups(expr, &1) != nil))
  end

  defp has_additive_op?(expr) do
    find_operator_outside_groups(expr, " + ") != nil or
      find_operator_outside_groups(expr, " - ") != nil
  end

  defp translate_binary_op(expr, ops, mode) do
    {op, pos} = find_rightmost_op(expr, ops)
    left = String.slice(expr, 0, pos) |> String.trim()
    right = String.slice(expr, (pos + String.length(op))..-1//1) |> String.trim()
    elixir_op = String.trim(op)
    "(#{do_translate(left, mode)} #{elixir_op} #{do_translate(right, mode)})"
  end

  defp translate_comparison(expr, mode) do
    ops = [" == ", " != ", " <= ", " >= ", " < ", " > "]
    {op, pos} = find_rightmost_op(expr, ops)
    left = String.slice(expr, 0, pos) |> String.trim()
    right = String.slice(expr, (pos + String.length(op))..-1//1) |> String.trim()
    elixir_op = String.trim(op)
    "(#{do_translate(left, mode)} #{elixir_op} #{do_translate(right, mode)})"
  end

  defp translate_bitwise(expr, mode) do
    ops = [" | ", " & ", " ^ "]
    {op, pos} = find_rightmost_op(expr, ops)
    left = String.slice(expr, 0, pos) |> String.trim()
    right = String.slice(expr, (pos + String.length(op))..-1//1) |> String.trim()

    fn_name = case String.trim(op) do
      "|" -> "bor"
      "&" -> "band"
      "^" -> "bxor"
    end

    "Bitwise.#{fn_name}(#{do_translate(left, mode)}, #{do_translate(right, mode)})"
  end

  defp translate_shift(expr, mode) do
    ops = [" << ", " >> "]
    {op, pos} = find_rightmost_op(expr, ops)
    left = String.slice(expr, 0, pos) |> String.trim()
    right = String.slice(expr, (pos + String.length(op))..-1//1) |> String.trim()

    fn_name = case String.trim(op) do
      "<<" -> "bsl"
      ">>" -> "bsr"
    end

    "Bitwise.#{fn_name}(#{do_translate(left, mode)}, #{do_translate(right, mode)})"
  end

  defp translate_additive(expr, mode) do
    {op, pos} = find_rightmost_additive_op(expr)
    left = String.slice(expr, 0, pos) |> String.trim()
    right = String.slice(expr, (pos + String.length(op))..-1//1) |> String.trim()

    left_t = do_translate(left, mode)
    right_t = do_translate(right, mode)

    cond do
      String.trim(op) != "+" ->
        "(#{left_t} #{String.trim(op)} #{right_t})"
      is_string_expr?(left) or is_string_expr?(right) ->
        "#{left_t} <> #{right_t}"
      is_numeric_expr?(left) and is_numeric_expr?(right) ->
        "(#{left_t} + #{right_t})"
      true ->
        # Could be string concat or arithmetic - decide at runtime
        "Ksc.Stream.kaitai_add(#{left_t}, #{right_t})"
    end
  end

  defp translate_multiplicative(expr, mode) do
    ops = [" * ", " / ", " % "]
    {op, pos} = find_rightmost_op(expr, ops)
    left = String.slice(expr, 0, pos) |> String.trim()
    right = String.slice(expr, (pos + String.length(op))..-1//1) |> String.trim()

    case String.trim(op) do
      "*" -> "(#{do_translate(left, mode)} * #{do_translate(right, mode)})"
      "/" -> "Ksc.Stream.floor_div(#{do_translate(left, mode)}, #{do_translate(right, mode)})"
      "%" -> "Ksc.Stream.floor_mod(#{do_translate(left, mode)}, #{do_translate(right, mode)})"
    end
  end

  defp translate_dot_access(expr, mode) do
    case find_last_dot(expr) do
      nil -> expr
      pos ->
        obj = String.slice(expr, 0, pos) |> String.trim()
        method = String.slice(expr, (pos + 1)..-1//1) |> String.trim()

        case method do
          "size" ->
            if String.ends_with?(obj, "._io") do
              # X._io.size -> size of the IO stream for X
              inner = String.slice(obj, 0..-5//1)
              "Ksc.Stream.kaitai_io_size(#{do_translate(inner, mode)})"
            else
              "Ksc.Stream.kaitai_size(#{do_translate(obj, mode)})"
            end
          "length" -> "Ksc.Stream.kaitai_length(#{do_translate(obj, mode)})"
          "to_i" ->
            # Check if the object is a cross-module enum reference (contains ::)
            if String.contains?(obj, "::") do
              parts = String.split(obj, "::")
              value = List.last(parts) |> String.trim()
              # Build module path for the enum's reverse map
              # e.g., "enum_0::animal::cat" -> use @kaitai_enum_reverse from local (inherited enums)
              "Ksc.Stream.to_i(:#{value}, @kaitai_enum_reverse)"
            else
              "Ksc.Stream.to_i(#{do_translate(obj, mode)}, @kaitai_enum_reverse)"
            end
          "to_s" -> "to_string(#{do_translate(obj, mode)})"
          "to_f" -> "(#{do_translate(obj, mode)} / 1.0)"
          "reverse" -> ":binary.bin_to_list(#{do_translate(obj, mode)}) |> Enum.reverse() |> :binary.list_to_bin()"
          "first" -> "Ksc.Stream.kaitai_first(#{do_translate(obj, mode)})"
          "last" -> "Ksc.Stream.kaitai_last(#{do_translate(obj, mode)})"
          "min" -> "Ksc.Stream.kaitai_min(#{do_translate(obj, mode)})"
          "max" -> "Ksc.Stream.kaitai_max(#{do_translate(obj, mode)})"
          "as_s" -> "#{do_translate(obj, mode)}"
          "_sizeof" ->
            # field._sizeof -> if obj is a simple field access, look up from parent
            # e.g. block1.a._sizeof -> result[:block1][:_sizeof_a] (parent stores field sizes)
            # e.g. block1._sizeof -> result[:block1][:_sizeof] (map stores own sizeof)
            case find_last_dot(obj) do
              nil ->
                # Simple field: e.g. block1._sizeof
                translated_obj = do_translate(obj, mode)
                "Ksc.Stream.kaitai_sizeof(#{translated_obj})"
              parent_dot ->
                parent_obj = String.slice(obj, 0, parent_dot) |> String.trim()
                field_name = String.slice(obj, (parent_dot + 1)..-1//1) |> String.trim()
                translated_parent = do_translate(parent_obj, mode)
                # Try the field's own _sizeof first, fall back to parent's _sizeof_field
                "(#{translated_parent}[:_sizeof_#{field_name}] || Ksc.Stream.kaitai_sizeof(#{translated_parent}[:#{field_name}]))"
            end
          "_io" ->
            # ._io returns the object itself (it stores _io_data and _io_size)
            do_translate(obj, mode)
          _ ->
            cond do
              # .as<Type> cast - no-op in Elixir (dynamically typed)
              String.starts_with?(method, "as<") ->
                do_translate(obj, mode)
              # .substring(from, to) -> binary_part(str, from, to - from)
              String.starts_with?(method, "substring(") ->
                args = String.trim_leading(method, "substring(") |> String.trim_trailing(")")
                case String.split(args, ",") do
                  [from, to] ->
                    from_t = do_translate(String.trim(from), mode)
                    to_t = do_translate(String.trim(to), mode)
                    "binary_part(#{do_translate(obj, mode)}, #{from_t}, #{to_t} - #{from_t})"
                  _ ->
                    "#{do_translate(obj, mode)}"
                end
              # .to_i(base) -> String.to_integer(str, base)
              String.starts_with?(method, "to_i(") ->
                args = String.trim_leading(method, "to_i(") |> String.trim_trailing(")")
                "String.to_integer(#{do_translate(obj, mode)}, #{do_translate(String.trim(args), mode)})"
              # .to_s(encoding) -> just return the binary (encoding handled at parse time)
              String.starts_with?(method, "to_s(") ->
                do_translate(obj, mode)
              true ->
                translated_obj = do_translate(obj, mode)
                # Field access on a parsed result - use map access
                cond do
                  Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*$/, method) ->
                    "#{translated_obj}[:#{method}]"
                  # Method part contains array access like "sizes[idx]" - split and handle
                  Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*\[/, method) ->
                    # Re-translate the whole expression by first translating obj.field, then the array part
                    case Regex.run(~r/^([a-z_][a-zA-Z0-9_]*)\[(.+)\]$/, method) do
                      [_, field, idx_expr] ->
                        "Ksc.Stream.kaitai_at(#{translated_obj}[:#{field}], #{do_translate(idx_expr, mode)})"
                      nil ->
                        "#{translated_obj}.#{method}"
                    end
                  true ->
                    "#{translated_obj}.#{method}"
                end
            end
        end
    end
  end

  defp has_dot_access?(expr), do: find_last_dot(expr) != nil

  defp find_last_dot(expr) do
    chars = String.graphemes(expr)
    len = length(chars)

    result =
      Enum.reduce(Enum.with_index(chars), {nil, 0, 0, false}, fn {ch, idx}, {last_dot, pd, bd, ins} ->
        {new_ins, new_pd, new_bd} =
          case ch do
            "\"" -> {!ins, pd, bd}
            "(" when not ins -> {false, pd + 1, bd}
            ")" when not ins -> {false, max(pd - 1, 0), bd}
            "[" when not ins -> {false, pd, bd + 1}
            "]" when not ins -> {false, pd, max(bd - 1, 0)}
            _ -> {ins, pd, bd}
          end

        new_last_dot =
          if ch == "." and not new_ins and new_pd == 0 and new_bd == 0 and idx + 1 < len do
            next_ch = Enum.at(chars, idx + 1)
            if next_ch != nil and Regex.match?(~r/[a-zA-Z_]/, next_ch), do: idx, else: last_dot
          else
            last_dot
          end

        {new_last_dot, new_pd, new_bd, new_ins}
      end)

    elem(result, 0)
  end

  defp has_array_access?(expr) do
    String.contains?(expr, "[") and String.ends_with?(expr, "]") and
      not String.starts_with?(expr, "[")
  end

  defp translate_array_access(expr, mode) do
    case find_matching_bracket_from_end(expr) do
      nil -> expr
      bracket_pos ->
        obj = String.slice(expr, 0, bracket_pos) |> String.trim()
        idx_expr = String.slice(expr, (bracket_pos + 1)..-2//1) |> String.trim()
        "Ksc.Stream.kaitai_at(#{do_translate(obj, mode)}, #{do_translate(idx_expr, mode)})"
    end
  end

  defp find_matching_bracket_from_end(expr) do
    chars = String.graphemes(expr)
    len = length(chars)

    if Enum.at(chars, len - 1) == "]" do
      {pos, _} =
        Enum.reduce_while((len - 1)..0//-1, {nil, 0}, fn idx, {_, depth} ->
          case Enum.at(chars, idx) do
            "]" -> {:cont, {nil, depth + 1}}
            "[" ->
              new_depth = depth - 1
              if new_depth == 0, do: {:halt, {idx, 0}}, else: {:cont, {nil, new_depth}}
            _ -> {:cont, {nil, depth}}
          end
        end)
      pos
    else
      nil
    end
  end

  defp translate_identifier(name, mode) do
    case name do
      "_root" -> "root_"
      "_parent" -> "parent_"
      "_io" -> "_io"
      "_index" -> "var__index"
      "_sizeof" -> "__sizeof__()"
      "_" when mode == :repeat_until -> "item"
      "_" -> "_"
      "true" -> "true"
      "false" -> "false"
      "null" -> "nil"
      _ ->
        case mode do
          :parse -> "var_#{name}"
          :repeat_until -> "var_#{name}"
          :instance -> "result[:#{name}]"
        end
    end
  end

  defp is_numeric_expr?(expr) do
    t = String.trim(expr)
    cond do
      is_integer_literal?(t) -> true
      is_float_literal?(t) -> true
      String.starts_with?(t, "0x") -> true
      t == "_io.pos" or t == "_io.size" -> true
      String.ends_with?(t, ".to_i") -> true
      String.ends_with?(t, ".size") -> true
      String.ends_with?(t, ".length") -> true
      # Arithmetic ops
      String.contains?(t, " * ") or String.contains?(t, " / ") or String.contains?(t, " % ") -> true
      true -> false
    end
  end

  defp is_string_expr?(expr) do
    t = String.trim(expr)
    cond do
      String.starts_with?(t, "\"") and String.ends_with?(t, "\"") -> true
      String.ends_with?(t, ".to_s") -> true
      String.ends_with?(t, ".as_s") -> true
      # String concatenation chain: contains " + " with a string literal somewhere
      String.contains?(t, " + ") and (String.contains?(t, "\"") or String.contains?(t, ".to_s")) -> true
      true -> false
    end
  end

  defp is_integer_literal?(expr) do
    case Integer.parse(expr) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp is_float_literal?(expr) do
    case Float.parse(expr) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp find_operator_outside_groups(expr, op) do
    op_len = String.length(op)
    chars = String.graphemes(expr)
    len = length(chars)

    if len < op_len do
      nil
    else
      Enum.reduce_while(0..(len - op_len), {nil, 0, 0, false}, fn idx, {_, pd, bd, ins} ->
        ch = Enum.at(chars, idx)

        {new_ins, new_pd, new_bd} =
          case ch do
            "\"" -> {!ins, pd, bd}
            "(" when not ins -> {false, pd + 1, bd}
            ")" when not ins -> {false, max(pd - 1, 0), bd}
            "[" when not ins -> {false, pd, bd + 1}
            "]" when not ins -> {false, pd, max(bd - 1, 0)}
            _ -> {ins, pd, bd}
          end

        if not new_ins and new_pd == 0 and new_bd == 0 do
          if String.slice(expr, idx, op_len) == op do
            {:halt, {idx, new_pd, new_bd, new_ins}}
          else
            {:cont, {nil, new_pd, new_bd, new_ins}}
          end
        else
          {:cont, {nil, new_pd, new_bd, new_ins}}
        end
      end)
      |> elem(0)
    end
  end

  defp find_rightmost_op(expr, ops) do
    results =
      Enum.flat_map(ops, fn op ->
        find_all_positions(expr, op) |> Enum.map(&{op, &1})
      end)

    if results == [], do: {nil, nil}, else: Enum.max_by(results, &elem(&1, 1))
  end

  defp find_rightmost_additive_op(expr) do
    results =
      Enum.flat_map([" + ", " - "], fn op ->
        find_all_positions(expr, op) |> Enum.map(&{op, &1})
      end)

    if results == [], do: {nil, nil}, else: Enum.max_by(results, &elem(&1, 1))
  end

  defp find_all_positions(expr, op) do
    op_len = String.length(op)
    chars = String.graphemes(expr)
    len = length(chars)

    if len < op_len do
      []
    else
      {positions, _, _, _} =
        Enum.reduce(0..(len - op_len), {[], 0, 0, false}, fn idx, {acc, pd, bd, ins} ->
          ch = Enum.at(chars, idx)

          {new_ins, new_pd, new_bd} =
            case ch do
              "\"" -> {!ins, pd, bd}
              "(" when not ins -> {false, pd + 1, bd}
              ")" when not ins -> {false, max(pd - 1, 0), bd}
              "[" when not ins -> {false, pd, bd + 1}
              "]" when not ins -> {false, pd, max(bd - 1, 0)}
              _ -> {ins, pd, bd}
            end

          if not new_ins and new_pd == 0 and new_bd == 0 and String.slice(expr, idx, op_len) == op do
            {[idx | acc], new_pd, new_bd, new_ins}
          else
            {acc, new_pd, new_bd, new_ins}
          end
        end)

      Enum.reverse(positions)
    end
  end
end
