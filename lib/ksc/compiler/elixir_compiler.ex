defmodule Ksc.Compiler.ElixirCompiler do
  @moduledoc "Generates Elixir source code from ClassSpec structs."

  alias Ksc.Format.{ClassSpec, AttrSpec, InstanceSpec}
  alias Ksc.Compiler.Utils

  @doc "Compile a ClassSpec into an Elixir source code string."
  def compile(%ClassSpec{} = spec) do
    mod_name = Utils.to_module_name(spec.id)
    type_registry = build_type_registry(spec, mod_name)
    # Collect ALL enums from the entire type hierarchy
    all_enums = collect_all_enums(spec)
    compile_module(spec, nil, type_registry, mod_name, all_enums)
  end

  # Recursively collect all enums from the entire type hierarchy
  defp collect_all_enums(%ClassSpec{} = spec) do
    own_enums = spec.enums
    child_enums = Enum.reduce(spec.types, %{}, fn {_name, type_spec}, acc ->
      Map.merge(acc, collect_all_enums(type_spec))
    end)
    Map.merge(own_enums, child_enums)
  end

  defp build_type_registry(%ClassSpec{} = spec, prefix) do
    Enum.reduce(spec.types, %{}, fn {name, type_spec}, acc ->
      mod_path = "#{prefix}.#{Utils.to_module_name(name)}"
      acc = Map.put(acc, name, mod_path)
      nested = build_type_registry(type_spec, mod_path)
      Map.merge(acc, nested)
    end)
  end

  defp compile_module(%ClassSpec{} = spec, parent_endian, type_registry, mod_name, all_enums) do
    endian = spec.endian || parent_endian

    # Merge this module's enums with inherited ones
    all_enums = Map.merge(all_enums, spec.enums)

    enum_code = compile_enums(all_enums)

    nested_modules =
      Enum.map(spec.types, fn {name, type_spec} ->
        nested_mod_name = "#{mod_name}.#{Utils.to_module_name(name)}"
        compile_module(type_spec, endian, type_registry, nested_mod_name, all_enums)
      end)

    parse_fn = compile_parse_function(spec, endian, type_registry)
    instance_fns = compile_instances(spec.instances, endian, type_registry, spec)
    public_api = compile_public_api(spec)

    body_parts =
      [enum_code | nested_modules] ++ [public_api, parse_fn | instance_fns]

    body =
      body_parts
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    short_name = mod_name |> String.split(".") |> List.last()

    """
    defmodule #{short_name} do
    #{Utils.indent(body, 1)}
    end
    """
    |> String.trim()
  end

  defp compile_public_api(%ClassSpec{} = spec) do
    has_instances = map_size(spec.instances) > 0

    from_binary =
      if has_instances do
        """
        def from_file(path) do
          from_binary(File.read!(path))
        end

        def from_binary(data) when is_binary(data) do
          {result, _rest} = parse(data, data)
          resolve_instances(result, data)
        end
        """
      else
        """
        def from_file(path) do
          from_binary(File.read!(path))
        end

        def from_binary(data) when is_binary(data) do
          {result, _rest} = parse(data, data)
          result
        end
        """
      end

    String.trim(from_binary)
  end

  defp compile_parse_function(%ClassSpec{} = spec, endian, type_registry) do
    if spec.seq == [] do
      "def parse(data, _root) do\n  {%{}, data}\nend"
    else
      # Auto-number anonymous fields
      {seq_with_ids, _} = Enum.reduce(spec.seq, {[], 0}, fn attr, {acc, anon_idx} ->
        if attr.id == nil or attr.id == "" do
          {acc ++ [%{attr | id: "_anon_#{anon_idx}"}], anon_idx + 1}
        else
          {acc ++ [attr], anon_idx}
        end
      end)

      field_parses =
        Enum.map(seq_with_ids, fn attr ->
          compile_attr_parse(attr, endian, type_registry, spec)
        end)

      field_names = Enum.map(seq_with_ids, fn attr -> attr.id end)

      result_map =
        field_names
        |> Enum.map(fn name -> "#{name}: var_#{name}" end)
        |> Enum.join(", ")

      body = Enum.join(field_parses, "\n")

      """
      def parse(data, root) do
        rest = data
      #{Utils.indent(body, 1)}
        {%{#{result_map}}, rest}
      end
      """
      |> String.trim()
    end
  end

  defp compile_attr_parse(%AttrSpec{} = attr, endian, type_registry, spec) do
    var = "var_#{attr.id}"

    cond do
      attr.contents != nil ->
        compile_contents_parse(attr, var)

      attr.repeat != nil ->
        compile_repeat_parse(attr, endian, var, type_registry, spec)

      attr.if_expr != nil ->
        compile_conditional_parse(attr, endian, var, type_registry, spec)

      true ->
        compile_simple_parse(attr, endian, var, type_registry, spec)
    end
  end

  defp compile_simple_parse(%AttrSpec{} = attr, endian, var, type_registry, spec) do
    {match, type_info} = type_to_pattern(attr.type, endian, attr, type_registry, spec)

    code = case type_info do
      :user_type ->
        type_mod = resolve_type_module(attr.type, type_registry, spec)
        if attr.size != nil do
          # Sized user type: extract substream, parse, advance rest
          size_expr = translate_expr(attr.size)
          """
          size_#{attr.id} = #{size_expr}
          <<#{var}_data::binary-size(size_#{attr.id}), rest::binary>> = rest
          {#{var}, _} = #{type_mod}.parse(#{var}_data, root)
          """
          |> String.trim()
        else
          "{#{var}, rest} = #{type_mod}.parse(rest, root)"
        end

      :switch ->
        if attr.size != nil do
          # Sized switch: extract substream, switch-parse inside it
          size_expr = translate_expr(attr.size)
          switch_code = compile_switch_parse_inner(attr, endian, "#{var}_data", type_registry, spec)
          """
          size_#{attr.id} = #{size_expr}
          <<#{var}_data::binary-size(size_#{attr.id}), rest::binary>> = rest
          {#{var}, _} = #{switch_code}
          """
          |> String.trim()
        else
          compile_switch_parse(attr, endian, var, type_registry, spec)
        end

      :bytes ->
        size_expr = translate_expr(attr.size)
        code = "size_#{attr.id} = #{size_expr}\n<<#{var}::binary-size(size_#{attr.id}), rest::binary>> = rest"
        maybe_apply_byte_processing(code, attr, var)

      :bytes_eos ->
        code = "#{var} = rest\nrest = <<>>"
        maybe_apply_byte_processing(code, attr, var)

      :str ->
        size_expr = translate_expr(attr.size)
        "size_#{attr.id} = #{size_expr}\n<<#{var}::binary-size(size_#{attr.id}), rest::binary>> = rest"

      :str_eos ->
        "#{var} = rest\nrest = <<>>"

      :strz ->
        "{#{var}, rest} = Ksc.Stream.read_strz(rest)"

      :terminated ->
        # Field with terminator but no size - scan for terminator
        consume = if attr.consume == false, do: "false", else: "true"
        include = if attr.include == true, do: "true", else: "false"
        "{#{var}, rest} = Ksc.Stream.read_terminated(rest, #{attr.terminator}, #{consume}, #{include})"

      {:bit, size} ->
        "{#{var}, rest} = Ksc.Stream.read_bits(rest, #{size})"

      _ ->
        "<<#{var}::#{match}, rest::binary>> = rest"
    end

    maybe_wrap_enum(code, attr, var)
  end

  defp compile_contents_parse(%AttrSpec{} = attr, var) do
    bytes = attr.contents
    size = length(bytes)
    byte_str = Enum.map(bytes, fn b -> Integer.to_string(b) end) |> Enum.join(", ")

    """
    <<#{var}::binary-size(#{size}), rest::binary>> = rest
    <<#{byte_str}>> = #{var}
    """
    |> String.trim()
  end

  defp compile_conditional_parse(%AttrSpec{} = attr, endian, var, type_registry, spec) do
    condition = translate_expr(attr.if_expr)
    inner_attr = %{attr | if_expr: nil}
    inner_code = compile_attr_parse(inner_attr, endian, type_registry, spec)

    """
    {#{var}, rest} = if #{condition} do
      #{Utils.indent(inner_code, 1)}
      {var_#{attr.id}, rest}
    else
      {nil, rest}
    end
    """
    |> String.trim()
  end

  defp compile_repeat_parse(%AttrSpec{} = attr, endian, var, type_registry, spec) do
    case attr.repeat do
      "expr" -> compile_repeat_expr(attr, endian, var, type_registry, spec)
      "eos" -> compile_repeat_eos(attr, endian, var, type_registry, spec)
      "until" -> compile_repeat_until(attr, endian, var, type_registry, spec)
    end
  end

  defp compile_repeat_expr(%AttrSpec{} = attr, endian, var, type_registry, spec) do
    count = translate_expr(attr.repeat_expr)
    inner_attr = %{attr | repeat: nil, repeat_expr: nil, if_expr: nil}
    inner_code = compile_simple_parse(inner_attr, endian, "item", type_registry, spec)
    inner_code = String.replace(inner_code, "var_#{attr.id}", "item")

    """
    {#{var}, rest} = Enum.reduce(1..max(#{count}, 0)//1, {[], rest}, fn _, {acc, rest} ->
      #{Utils.indent(inner_code, 1)}
      {acc ++ [item], rest}
    end)
    """
    |> String.trim()
  end

  defp compile_repeat_eos(%AttrSpec{} = attr, endian, var, type_registry, spec) do
    inner_attr = %{attr | repeat: nil, repeat_expr: nil, if_expr: nil}
    inner_code = compile_simple_parse(inner_attr, endian, "item", type_registry, spec)
    inner_code = String.replace(inner_code, "var_#{attr.id}", "item")

    """
    {#{var}, rest} = Ksc.Stream.repeat_eos(rest, fn rest ->
      #{Utils.indent(inner_code, 1)}
      {item, rest}
    end)
    """
    |> String.trim()
  end

  defp compile_repeat_until(%AttrSpec{} = attr, endian, var, type_registry, spec) do
    inner_attr = %{attr | repeat: nil, repeat_expr: nil, repeat_until: nil, if_expr: nil}
    inner_code = compile_simple_parse(inner_attr, endian, "item", type_registry, spec)
    inner_code = String.replace(inner_code, "var_#{attr.id}", "item")
    condition = translate_expr_for_repeat_until(attr.repeat_until)

    """
    {#{var}, rest} = Ksc.Stream.repeat_until(rest, fn rest ->
      #{Utils.indent(inner_code, 1)}
      {item, rest}
    end, fn item, _acc -> #{condition} end)
    """
    |> String.trim()
  end

  defp compile_switch_parse(%AttrSpec{} = attr, endian, var, type_registry, spec) do
    inner = compile_switch_parse_inner(attr, endian, "rest", type_registry, spec)
    """
    {#{var}, rest} = #{inner}
    """
    |> String.trim()
  end

  defp compile_switch_parse_inner(%AttrSpec{} = attr, endian, data_var, type_registry, spec) do
    %{"switch-on" => switch_expr, "cases" => cases} = attr.type
    switch_val = translate_expr(switch_expr)

    case_clauses =
      Enum.map(cases, fn {case_key, case_type} ->
        case_val = translate_case_key(case_key)
        inner_attr = %{attr | type: case_type, if_expr: nil, repeat: nil, size: nil}
        inner_code = compile_simple_parse(inner_attr, endian, "switch_val", type_registry, spec)
        # Replace "rest" references with our data variable
        inner_code = if data_var != "rest" do
          String.replace(inner_code, "rest", data_var)
        else
          inner_code
        end

        """
          #{case_val} ->
            #{Utils.indent(inner_code, 3)}
            {switch_val, #{data_var}}
        """
        |> String.trim_trailing()
      end)
      |> Enum.join("\n")

    # Add a catch-all if there's no "_" case
    has_default = Enum.any?(cases, fn {k, _} -> k == "_" end)
    case_clauses = if has_default do
      case_clauses
    else
      case_clauses <> "\n  _ ->\n      {nil, #{data_var}}"
    end

    """
    case #{switch_val} do
    #{case_clauses}
    end
    """
    |> String.trim()
  end

  # Translate case keys - handle enum references like "enum_name::value"
  defp translate_case_key(key) when is_binary(key) do
    cond do
      String.contains?(key, "::") ->
        # Enum reference: "enum_name::value" -> :value
        parts = String.split(key, "::")
        value = List.last(parts)
        ":#{value}"

      key == "_" ->
        "_"

      key == "true" ->
        "true"

      key == "false" ->
        "false"

      String.starts_with?(key, "\"") ->
        key

      true ->
        translate_expr(key)
    end
  end

  defp translate_case_key(key) when is_integer(key), do: Integer.to_string(key)
  defp translate_case_key(key), do: to_string(key)

  defp compile_instances(instances, endian, type_registry, spec) do
    if map_size(instances) == 0 do
      []
    else
      resolve_fn = compile_resolve_instances(instances, endian, type_registry, spec)
      [resolve_fn]
    end
  end

  defp compile_resolve_instances(instances, endian, type_registry, spec) do
    assignments =
      Enum.map(instances, fn {name, %InstanceSpec{} = inst} ->
        cond do
          inst.value != nil ->
            expr = translate_expr_for_instance(inst.value)
            "result = Map.put(result, :#{name}, #{expr})"

          inst.pos != nil and inst.type != nil ->
            # Parse instance: seek to position and parse
            pos_expr = translate_expr_for_instance(inst.pos)
            compile_parse_instance(name, inst, pos_expr, endian, type_registry, spec)

          inst.type != nil and inst.size != nil ->
            # Sized parse instance
            size_expr = translate_expr_for_instance(inst.size)
            compile_sized_parse_instance(name, inst, size_expr, endian, type_registry, spec)

          true ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if assignments == "" do
      "defp resolve_instances(result, _root_data), do: result"
    else
      """
      defp resolve_instances(result, root_data) do
        #{assignments}
        result
      end
      """
      |> String.trim()
    end
  end

  defp compile_parse_instance(name, inst, pos_expr, endian, type_registry, spec) do
    {_match, type_info} = type_to_pattern(inst.type, endian, %AttrSpec{size: inst.size, size_eos: inst.size_eos}, type_registry, spec)

    case type_info do
      :user_type ->
        type_mod = resolve_type_module(inst.type, type_registry, spec)
        """
        inst_data = binary_part(root_data, #{pos_expr}, byte_size(root_data) - #{pos_expr})
        {inst_val, _} = #{type_mod}.parse(inst_data, root_data)
        result = Map.put(result, :#{name}, inst_val)
        """
        |> String.trim()

      :primitive ->
        {match, _} = type_to_pattern(inst.type, endian, %AttrSpec{}, type_registry, spec)
        """
        inst_data = binary_part(root_data, #{pos_expr}, byte_size(root_data) - #{pos_expr})
        <<inst_val::#{match}, _::binary>> = inst_data
        result = Map.put(result, :#{name}, inst_val)
        """
        |> String.trim()

      _ ->
        "result = Map.put(result, :#{name}, nil)"
    end
  end

  defp compile_sized_parse_instance(name, inst, size_expr, endian, type_registry, spec) do
    {_match, type_info} = type_to_pattern(inst.type, endian, %AttrSpec{size: inst.size}, type_registry, spec)

    case type_info do
      :user_type ->
        type_mod = resolve_type_module(inst.type, type_registry, spec)
        """
        inst_size = #{size_expr}
        <<inst_data::binary-size(inst_size), _::binary>> = root_data
        {inst_val, _} = #{type_mod}.parse(inst_data, root_data)
        result = Map.put(result, :#{name}, inst_val)
        """
        |> String.trim()

      _ ->
        "result = Map.put(result, :#{name}, nil)"
    end
  end

  defp type_to_pattern(nil, _endian, attr, _type_registry, _spec) do
    cond do
      attr.size != nil -> {"", :bytes}
      attr.size_eos == true -> {"", :bytes_eos}
      Map.get(attr, :terminator) != nil -> {"", :terminated}
      true -> {"binary", :raw}
    end
  end

  defp type_to_pattern(type, endian, attr, type_registry, spec) when is_binary(type) do
    cond do
      # Bit types: b1 through b64
      Regex.match?(~r/^b\d+$/, type) ->
        bit_size = String.trim_leading(type, "b") |> String.to_integer()
        {"", {:bit, bit_size}}

      true ->
        case type do
          "u1" -> {"unsigned-integer-size(8)", :primitive}
          "s1" -> {"signed-integer-size(8)", :primitive}
          "u2" -> {"unsigned-integer-#{endian_str(endian)}-size(16)", :primitive}
          "u2le" -> {"unsigned-integer-little-size(16)", :primitive}
          "u2be" -> {"unsigned-integer-big-size(16)", :primitive}
          "s2" -> {"signed-integer-#{endian_str(endian)}-size(16)", :primitive}
          "s2le" -> {"signed-integer-little-size(16)", :primitive}
          "s2be" -> {"signed-integer-big-size(16)", :primitive}
          "u4" -> {"unsigned-integer-#{endian_str(endian)}-size(32)", :primitive}
          "u4le" -> {"unsigned-integer-little-size(32)", :primitive}
          "u4be" -> {"unsigned-integer-big-size(32)", :primitive}
          "s4" -> {"signed-integer-#{endian_str(endian)}-size(32)", :primitive}
          "s4le" -> {"signed-integer-little-size(32)", :primitive}
          "s4be" -> {"signed-integer-big-size(32)", :primitive}
          "u8" -> {"unsigned-integer-#{endian_str(endian)}-size(64)", :primitive}
          "u8le" -> {"unsigned-integer-little-size(64)", :primitive}
          "u8be" -> {"unsigned-integer-big-size(64)", :primitive}
          "s8" -> {"signed-integer-#{endian_str(endian)}-size(64)", :primitive}
          "s8le" -> {"signed-integer-little-size(64)", :primitive}
          "s8be" -> {"signed-integer-big-size(64)", :primitive}
          "f4" -> {"float-#{endian_str(endian)}-size(32)", :primitive}
          "f4le" -> {"float-little-size(32)", :primitive}
          "f4be" -> {"float-big-size(32)", :primitive}
          "f8" -> {"float-#{endian_str(endian)}-size(64)", :primitive}
          "f8le" -> {"float-little-size(64)", :primitive}
          "f8be" -> {"float-big-size(64)", :primitive}
          "str" ->
            cond do
              attr.size != nil -> {"", :str}
              Map.get(attr, :terminator) != nil -> {"", :terminated}
              attr.size_eos == true -> {"", :str_eos}
              true -> {"", :str_eos}
            end
          "strz" ->
            {"", :strz}
          _ ->
            if is_user_type?(type, type_registry, spec) do
              {"", :user_type}
            else
              {"binary", :raw}
            end
        end
    end
  end

  defp type_to_pattern(%{"switch-on" => _, "cases" => _}, _endian, _attr, _type_registry, _spec) do
    {"", :switch}
  end

  defp is_user_type?(type, type_registry, spec) do
    # Handle :: path separator (e.g., "subtype_a::subtype_cc")
    if String.contains?(type, "::") do
      true
    else
      Map.has_key?(type_registry, type) or Map.has_key?(spec.types, type)
    end
  end

  defp resolve_type_module(type, type_registry, spec) do
    if String.contains?(type, "::") do
      # Convert path like "subtype_a::subtype_cc" to "SubtypeA.SubtypeCc"
      parts = String.split(type, "::")
      Enum.map(parts, &Utils.to_module_name/1) |> Enum.join(".")
    else
      cond do
        Map.has_key?(spec.types, type) ->
          Utils.to_module_name(type)

        Map.has_key?(type_registry, type) ->
          Map.get(type_registry, type)

        true ->
          Utils.to_module_name(type)
      end
    end
  end

  defp endian_str(:le), do: "little"
  defp endian_str(:be), do: "big"
  defp endian_str(nil), do: "big"

  defp maybe_wrap_enum(code, %AttrSpec{enum: nil}, _var), do: code

  defp maybe_wrap_enum(code, %AttrSpec{enum: enum_name}, var) do
    # Handle cross-type enum references like "container1::animal"
    if String.contains?(enum_name, "::") do
      parts = String.split(enum_name, "::")
      # The last part is the enum name, earlier parts are type paths
      _type_path = Enum.slice(parts, 0..-2//1) |> Enum.map(&Utils.to_module_name/1) |> Enum.join(".")
      enum_id = List.last(parts)
      # For cross-type enums, we'd need the module reference, but since module attributes
      # are compile-time only in their own module, we inline the lookup
      code <> "\n#{var} = Map.get(@enum_#{enum_id}, #{var}, #{var})"
    else
      code <> "\n#{var} = Map.get(@enum_#{enum_name}, #{var}, #{var})"
    end
  end

  defp maybe_apply_byte_processing(code, %AttrSpec{} = attr, var) do
    code =
      if attr.pad_right != nil do
        code <> "\n#{var} = Ksc.Stream.strip_pad_right(#{var}, #{attr.pad_right})"
      else
        code
      end

    if attr.terminator != nil do
      code <> "\n#{var} = Ksc.Stream.terminate_at(#{var}, #{attr.terminator}, #{attr.include == true})"
    else
      code
    end
  end

  defp compile_enums(enums) when map_size(enums) == 0, do: ""

  defp compile_enums(enums) do
    Enum.map(enums, fn {name, %{values: values}} ->
      map_str =
        Enum.map(values, fn {k, v} -> "#{k} => :#{v}" end)
        |> Enum.join(", ")

      "@enum_#{name} %{#{map_str}}"
    end)
    |> Enum.join("\n")
  end

  defp translate_expr(nil), do: "nil"

  defp translate_expr(expr) when is_binary(expr) do
    Ksc.Expression.translate(escape_elixir_interpolation(expr))
  end

  defp translate_expr(val) when is_integer(val), do: Integer.to_string(val)
  defp translate_expr(val) when is_float(val), do: Float.to_string(val)

  # Instance expressions use result[:field] instead of var_field
  defp translate_expr_for_instance(nil), do: "nil"

  defp translate_expr_for_instance(expr) when is_binary(expr) do
    Ksc.Expression.translate_for_instance(escape_elixir_interpolation(expr))
  end

  defp translate_expr_for_instance(val) when is_integer(val), do: Integer.to_string(val)
  defp translate_expr_for_instance(val) when is_float(val), do: Float.to_string(val)

  # repeat-until uses _ as the current item reference
  defp translate_expr_for_repeat_until(expr) when is_binary(expr) do
    Ksc.Expression.translate_for_repeat_until(escape_elixir_interpolation(expr))
  end

  # Escape #{...} in string literals so Elixir doesn't try to interpolate them.
  # We do this at the KSY expression level before translation.
  defp escape_elixir_interpolation(expr) when is_binary(expr) do
    hash_brace = <<?#, ?{>>
    if String.contains?(expr, hash_brace) do
      # Walk through the expression char by char tracking whether we're inside quotes
      chars = String.to_charlist(expr)
      {result, _} = Enum.reduce(chars, {[], false}, fn
        ?", {acc, in_str} -> {[?" | acc], not in_str}
        ?#, {acc, true} -> {[?#, ?\\ | acc], true}  # escape # inside strings
        ch, {acc, in_str} -> {[ch | acc], in_str}
      end)
      List.to_string(Enum.reverse(result))
    else
      expr
    end
  end
end
