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
      expr == "" ->
        "nil"

      expr == "true" ->
        "true"

      expr == "false" ->
        "false"

      expr == "null" ->
        "nil"

      # Ternary: cond ? a : b
      (q_pos = find_operator_outside_groups(expr, " ? ")) != nil ->
        translate_ternary_at(expr, q_pos, mode)

      # Boolean operators
      (match = find_rightmost_op_outside_groups(expr, [" or ", " and "])) != nil ->
        translate_binary_op_at(expr, match, mode)

      # Comparison
      (match =
         find_rightmost_op_outside_groups(expr, [" == ", " != ", " <= ", " >= ", " < ", " > "])) !=
          nil ->
        translate_binary_op_at(expr, match, mode)

      # Bitwise
      (match = find_rightmost_op_outside_groups(expr, [" | ", " & ", " ^ "])) != nil ->
        translate_bitwise_at(expr, match, mode)

      # Shift
      (match = find_rightmost_op_outside_groups(expr, [" << ", " >> "])) != nil ->
        translate_shift_at(expr, match, mode)

      # Additive
      (match = find_rightmost_op_outside_groups(expr, [" + ", " - "])) != nil ->
        translate_additive_at(expr, match, mode)

      # Multiplicative
      (match = find_rightmost_op_outside_groups(expr, [" * ", " / ", " % "])) != nil ->
        translate_multiplicative_at(expr, match, mode)

      # Unary not
      String.starts_with?(expr, "not ") ->
        inner = binary_part(expr, 4, byte_size(expr) - 4) |> String.trim()
        "not (#{do_translate(inner, mode)})"

      # Unary negation (minus)
      String.starts_with?(expr, "-") and byte_size(expr) > 1 ->
        inner = binary_part(expr, 1, byte_size(expr) - 1) |> String.trim()

        if is_integer_literal?(inner) or is_float_literal?(inner) do
          "-#{inner}"
        else
          "-(#{do_translate(inner, mode)})"
        end

      # Unary bitwise complement
      String.starts_with?(expr, "~") ->
        inner = binary_part(expr, 1, byte_size(expr) - 1) |> String.trim()
        "Bitwise.bnot(#{do_translate(inner, mode)})"

      # Parenthesized
      String.starts_with?(expr, "(") and matching_paren_at_end?(expr) ->
        inner = binary_part(expr, 1, byte_size(expr) - 2)
        "(#{do_translate(inner, mode)})"

      # f-string (formatted string): f"abc={expr}" -> "abc=#{expr}"
      String.starts_with?(expr, "f\"") and String.ends_with?(expr, "\"") ->
        translate_fstring(expr, mode)

      # String literal
      String.starts_with?(expr, "\"") and String.ends_with?(expr, "\"") ->
        expr

      # Hex literal
      String.starts_with?(expr, "0x") ->
        expr

      String.starts_with?(expr, "0o") ->
        expr

      # Integer literal
      is_integer_literal?(expr) ->
        expr

      # Float literal
      is_float_literal?(expr) ->
        expr

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

        mod_name =
          type_name
          |> String.split("::")
          |> Enum.map(fn part ->
            part |> String.split("_") |> Enum.map(&String.capitalize/1) |> Enum.join()
          end)
          |> Enum.join(".")

        "#{mod_name}.__sizeof__()"

      # Method/field access: expr.method
      (dot_pos = find_last_dot(expr)) != nil ->
        translate_dot_access_at(expr, dot_pos, mode)

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
    len = byte_size(expr)

    if len < 2 or :binary.at(expr, 0) != ?( or :binary.at(expr, len - 1) != ?) do
      false
    else
      do_matching_paren(expr, len - 1, 1, 1)
    end
  end

  defp do_matching_paren(_expr, max_idx, idx, _depth) when idx >= max_idx, do: true

  defp do_matching_paren(expr, max_idx, idx, depth) do
    new_depth =
      case :binary.at(expr, idx) do
        ?( -> depth + 1
        ?) -> depth - 1
        _ -> depth
      end

    if new_depth == 0 do
      false
    else
      do_matching_paren(expr, max_idx, idx + 1, new_depth)
    end
  end

  defp translate_fstring(expr, mode) do
    # f"text{expr}text" -> "text#{translated_expr}text"
    # Strip leading f and outer quotes
    inner = String.slice(expr, 2..-2//1)
    # Escape backslashes so \n stays literal in Elixir string
    inner = String.replace(inner, "\\", "\\\\")
    # Replace {expr} with Elixir interpolation #{translated_expr}
    result =
      Regex.replace(~r/\{([^}]+)\}/, inner, fn _, ksy_expr ->
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
      has_strings =
        Enum.any?(raw_items, &(String.starts_with?(&1, "\"") or String.starts_with?(&1, "'")))

      has_floats = Enum.any?(raw_items, &String.contains?(&1, "."))

      has_large_ints =
        Enum.any?(raw_items, fn s ->
          case Integer.parse(s) do
            {n, ""} -> n > 255 or n < 0
            _ -> false
          end
        end)

      # If any item is a non-literal (identifier, expression), use a list
      has_non_literals =
        Enum.any?(raw_items, fn s ->
          not (is_integer_literal?(s) or String.starts_with?(s, "0x") or
                 String.starts_with?(s, "0o") or
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

  defp translate_ternary_at(expr, q_pos, mode) do
    cond_part = binary_part(expr, 0, q_pos) |> String.trim()
    rest = binary_part(expr, q_pos + 3, byte_size(expr) - q_pos - 3) |> String.trim()

    case find_operator_outside_groups(rest, " : ") do
      nil ->
        expr

      colon_pos ->
        true_part = binary_part(rest, 0, colon_pos) |> String.trim()

        false_part =
          binary_part(rest, colon_pos + 3, byte_size(rest) - colon_pos - 3) |> String.trim()

        "if(#{do_translate(cond_part, mode)}, do: #{do_translate(true_part, mode)}, else: #{do_translate(false_part, mode)})"
    end
  end

  defp translate_binary_op_at(expr, {op, pos}, mode) do
    op_len = byte_size(op)
    left = binary_part(expr, 0, pos) |> String.trim()
    right = binary_part(expr, pos + op_len, byte_size(expr) - pos - op_len) |> String.trim()
    elixir_op = String.trim(op)
    "(#{do_translate(left, mode)} #{elixir_op} #{do_translate(right, mode)})"
  end

  defp translate_bitwise_at(expr, {op, pos}, mode) do
    op_len = byte_size(op)
    left = binary_part(expr, 0, pos) |> String.trim()
    right = binary_part(expr, pos + op_len, byte_size(expr) - pos - op_len) |> String.trim()

    fn_name =
      case String.trim(op) do
        "|" -> "bor"
        "&" -> "band"
        "^" -> "bxor"
      end

    "Bitwise.#{fn_name}(#{do_translate(left, mode)}, #{do_translate(right, mode)})"
  end

  defp translate_shift_at(expr, {op, pos}, mode) do
    op_len = byte_size(op)
    left = binary_part(expr, 0, pos) |> String.trim()
    right = binary_part(expr, pos + op_len, byte_size(expr) - pos - op_len) |> String.trim()

    fn_name =
      case String.trim(op) do
        "<<" -> "bsl"
        ">>" -> "bsr"
      end

    "Bitwise.#{fn_name}(#{do_translate(left, mode)}, #{do_translate(right, mode)})"
  end

  defp translate_additive_at(expr, {op, pos}, mode) do
    op_len = byte_size(op)
    left = binary_part(expr, 0, pos) |> String.trim()
    right = binary_part(expr, pos + op_len, byte_size(expr) - pos - op_len) |> String.trim()

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

  defp translate_multiplicative_at(expr, {op, pos}, mode) do
    op_len = byte_size(op)
    left = binary_part(expr, 0, pos) |> String.trim()
    right = binary_part(expr, pos + op_len, byte_size(expr) - pos - op_len) |> String.trim()

    case String.trim(op) do
      "*" -> "(#{do_translate(left, mode)} * #{do_translate(right, mode)})"
      "/" -> "Ksc.Stream.floor_div(#{do_translate(left, mode)}, #{do_translate(right, mode)})"
      "%" -> "Ksc.Stream.floor_mod(#{do_translate(left, mode)}, #{do_translate(right, mode)})"
    end
  end

  defp translate_dot_access_at(expr, dot_pos, mode) do
    obj = binary_part(expr, 0, dot_pos) |> String.trim()
    method = binary_part(expr, dot_pos + 1, byte_size(expr) - dot_pos - 1) |> String.trim()

    case method do
      "size" ->
        if String.ends_with?(obj, "._io") do
          # X._io.size -> size of the IO stream for X
          inner = binary_part(obj, 0, byte_size(obj) - 4)
          "Ksc.Stream.kaitai_io_size(#{do_translate(inner, mode)})"
        else
          "Ksc.Stream.kaitai_size(#{do_translate(obj, mode)})"
        end

      "length" ->
        "Ksc.Stream.kaitai_length(#{do_translate(obj, mode)})"

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

      "to_s" ->
        "to_string(#{do_translate(obj, mode)})"

      "to_f" ->
        "(#{do_translate(obj, mode)} / 1.0)"

      "reverse" ->
        ":binary.bin_to_list(#{do_translate(obj, mode)}) |> Enum.reverse() |> :binary.list_to_bin()"

      "first" ->
        "Ksc.Stream.kaitai_first(#{do_translate(obj, mode)})"

      "last" ->
        "Ksc.Stream.kaitai_last(#{do_translate(obj, mode)})"

      "min" ->
        "Ksc.Stream.kaitai_min(#{do_translate(obj, mode)})"

      "max" ->
        "Ksc.Stream.kaitai_max(#{do_translate(obj, mode)})"

      "as_s" ->
        "#{do_translate(obj, mode)}"

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
            parent_obj = binary_part(obj, 0, parent_dot) |> String.trim()

            field_name =
              binary_part(obj, parent_dot + 1, byte_size(obj) - parent_dot - 1) |> String.trim()

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

  defp has_array_access?(expr) do
    String.contains?(expr, "[") and String.ends_with?(expr, "]") and
      not String.starts_with?(expr, "[")
  end

  defp translate_array_access(expr, mode) do
    case find_matching_bracket_from_end(expr) do
      nil ->
        expr

      bracket_pos ->
        obj = binary_part(expr, 0, bracket_pos) |> String.trim()

        idx_expr =
          binary_part(expr, bracket_pos + 1, byte_size(expr) - bracket_pos - 2) |> String.trim()

        "Ksc.Stream.kaitai_at(#{do_translate(obj, mode)}, #{do_translate(idx_expr, mode)})"
    end
  end

  defp translate_identifier(name, mode) do
    case name do
      "_root" ->
        "root_"

      "_parent" ->
        "parent_"

      "_io" ->
        "_io"

      "_index" ->
        "var__index"

      "_sizeof" ->
        "__sizeof__()"

      "_" when mode == :repeat_until ->
        "item"

      "_" ->
        "_"

      "true" ->
        "true"

      "false" ->
        "false"

      "null" ->
        "nil"

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
      is_integer_literal?(t) ->
        true

      is_float_literal?(t) ->
        true

      String.starts_with?(t, "0x") ->
        true

      t == "_io.pos" or t == "_io.size" ->
        true

      String.ends_with?(t, ".to_i") ->
        true

      String.ends_with?(t, ".size") ->
        true

      String.ends_with?(t, ".length") ->
        true

      # Arithmetic ops
      String.contains?(t, " * ") or String.contains?(t, " / ") or String.contains?(t, " % ") ->
        true

      true ->
        false
    end
  end

  defp is_string_expr?(expr) do
    t = String.trim(expr)

    cond do
      String.starts_with?(t, "\"") and String.ends_with?(t, "\"") ->
        true

      String.ends_with?(t, ".to_s") ->
        true

      String.ends_with?(t, ".as_s") ->
        true

      # String concatenation chain: contains " + " with a string literal somewhere
      String.contains?(t, " + ") and (String.contains?(t, "\"") or String.contains?(t, ".to_s")) ->
        true

      true ->
        false
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

  # Single-pass scan for the rightmost operator among `ops`, respecting grouping.
  # Returns {op, pos} or nil.
  defp find_rightmost_op_outside_groups(expr, ops) do
    len = byte_size(expr)
    op_specs = Enum.map(ops, fn op -> {op, byte_size(op)} end)
    min_op_len = op_specs |> Enum.map(&elem(&1, 1)) |> Enum.min()

    if len < min_op_len do
      nil
    else
      do_find_rightmost(expr, len, op_specs, 0, 0, 0, false, nil)
    end
  end

  defp do_find_rightmost(expr, len, op_specs, idx, pd, bd, ins, acc) do
    if idx >= len do
      acc
    else
      ch = :binary.at(expr, idx)

      {new_ins, new_pd, new_bd} =
        case ch do
          ?\" -> {not ins, pd, bd}
          ?( when not ins -> {false, pd + 1, bd}
          ?) when not ins -> {false, max(pd - 1, 0), bd}
          ?[ when not ins -> {false, pd, bd + 1}
          ?] when not ins -> {false, pd, max(bd - 1, 0)}
          _ -> {ins, pd, bd}
        end

      new_acc =
        if not new_ins and new_pd == 0 and new_bd == 0 do
          Enum.reduce(op_specs, acc, fn {op, op_len}, best ->
            if idx + op_len <= len and :binary.part(expr, idx, op_len) == op do
              {op, idx}
            else
              best
            end
          end)
        else
          acc
        end

      do_find_rightmost(expr, len, op_specs, idx + 1, new_pd, new_bd, new_ins, new_acc)
    end
  end

  # Leftmost scan for a single operator outside groups. Returns position or nil.
  defp find_operator_outside_groups(expr, op) do
    op_len = byte_size(op)
    len = byte_size(expr)

    if len < op_len do
      nil
    else
      do_find_operator(expr, op, op_len, len, 0, 0, 0, false)
    end
  end

  defp do_find_operator(expr, op, op_len, len, idx, pd, bd, ins) do
    if idx + op_len > len do
      nil
    else
      ch = :binary.at(expr, idx)

      {new_ins, new_pd, new_bd} =
        case ch do
          ?\" -> {not ins, pd, bd}
          ?( when not ins -> {false, pd + 1, bd}
          ?) when not ins -> {false, max(pd - 1, 0), bd}
          ?[ when not ins -> {false, pd, bd + 1}
          ?] when not ins -> {false, pd, max(bd - 1, 0)}
          _ -> {ins, pd, bd}
        end

      if not new_ins and new_pd == 0 and new_bd == 0 and :binary.part(expr, idx, op_len) == op do
        idx
      else
        do_find_operator(expr, op, op_len, len, idx + 1, new_pd, new_bd, new_ins)
      end
    end
  end

  # Byte-level scan for the last dot that precedes a letter/underscore, outside groups.
  defp find_last_dot(expr) do
    len = byte_size(expr)
    do_find_last_dot(expr, len, 0, 0, 0, false, nil)
  end

  defp do_find_last_dot(expr, len, idx, pd, bd, ins, acc) do
    if idx >= len do
      acc
    else
      ch = :binary.at(expr, idx)

      {new_ins, new_pd, new_bd} =
        case ch do
          ?\" -> {not ins, pd, bd}
          ?( when not ins -> {false, pd + 1, bd}
          ?) when not ins -> {false, max(pd - 1, 0), bd}
          ?[ when not ins -> {false, pd, bd + 1}
          ?] when not ins -> {false, pd, max(bd - 1, 0)}
          _ -> {ins, pd, bd}
        end

      new_acc =
        if ch == ?. and not new_ins and new_pd == 0 and new_bd == 0 and idx + 1 < len do
          next_ch = :binary.at(expr, idx + 1)

          if (next_ch >= ?a and next_ch <= ?z) or (next_ch >= ?A and next_ch <= ?Z) or
               next_ch == ?_ do
            idx
          else
            acc
          end
        else
          acc
        end

      do_find_last_dot(expr, len, idx + 1, new_pd, new_bd, new_ins, new_acc)
    end
  end

  # Byte-level reverse scan for matching bracket from end.
  defp find_matching_bracket_from_end(expr) do
    len = byte_size(expr)

    if len == 0 or :binary.at(expr, len - 1) != ?] do
      nil
    else
      do_find_matching_bracket(expr, len - 1, 0)
    end
  end

  defp do_find_matching_bracket(_expr, idx, _depth) when idx < 0, do: nil

  defp do_find_matching_bracket(expr, idx, depth) do
    case :binary.at(expr, idx) do
      ?] ->
        do_find_matching_bracket(expr, idx - 1, depth + 1)

      ?[ ->
        new_depth = depth - 1
        if new_depth == 0, do: idx, else: do_find_matching_bracket(expr, idx - 1, new_depth)

      _ ->
        do_find_matching_bracket(expr, idx - 1, depth)
    end
  end
end
