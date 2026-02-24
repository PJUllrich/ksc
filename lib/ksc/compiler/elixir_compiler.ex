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
    has_params = (spec.params || []) != []

    # Don't generate from_binary for parameterized types
    if has_params do
      ""
    else

    from_binary =
      if has_instances do
        """
        def from_file(path) do
          from_binary(File.read!(path))
        end

        def from_binary(data) when is_binary(data) do
          {result, _rest} = parse(data, %{})
          resolve_instances(result, data)
        end
        """
      else
        """
        def from_file(path) do
          from_binary(File.read!(path))
        end

        def from_binary(data) when is_binary(data) do
          {result, _rest} = parse(data, %{})
          result
        end
        """
      end

    String.trim(from_binary)

    end # has_params else
  end

  defp compile_parse_function(%ClassSpec{} = spec, endian, type_registry) do
    params = spec.params || []
    param_names = Enum.map(params, fn p -> "var_#{p.id}" end)
    has_params = params != []

    if spec.seq == [] do
      if has_params do
        args = Enum.join(["data", "_root_", "_parent"] ++ param_names, ", ")
        "def parse(#{args}) do\n  {%{}, data}\nend"
      else
        "def parse(data, _root_, _parent \\\\ nil) do\n  {%{}, data}\nend"
      end
    else
      # Auto-number anonymous fields
      {seq_with_ids, _} = Enum.reduce(spec.seq, {[], 0}, fn attr, {acc, anon_idx} ->
        if attr.id == nil or attr.id == "" do
          {acc ++ [%{attr | id: "_anon_#{anon_idx}"}], anon_idx + 1}
        else
          {acc ++ [attr], anon_idx}
        end
      end)

      bit_endian = spec.bit_endian

      field_parses =
        compile_attr_parses_with_bits(seq_with_ids, endian, type_registry, spec, bit_endian)

      field_names = Enum.map(seq_with_ids, fn attr -> attr.id end)

      result_map =
        field_names
        |> Enum.map(fn name -> "#{name}: var_#{name}" end)
        |> Enum.join(", ")

      # Check if any user types exist (need result_so_far for parent passing)
      needs_parent_passing = Enum.any?(seq_with_ids, fn attr ->
        is_user_type_attr?(attr, endian, type_registry, spec)
      end)

      body = Enum.join(field_parses, "\n")

      # Check if any field uses _io.pos or _io.size
      all_exprs = collect_all_expressions(seq_with_ids)
      needs_io = Enum.any?(all_exprs, fn e -> is_binary(e) and (String.contains?(e, "_io.pos") or String.contains?(e, "_io.size") or String.contains?(e, "_io.eof")) end)

      io_init = if needs_io do
        "io_size = byte_size(data)"
      else
        nil
      end

      io_pos_code = if needs_io do
        "io_pos = io_size - byte_size(rest)"
      else
        nil
      end

      parent_init = if needs_parent_passing, do: "result_so_far = %{_parent: parent_}", else: nil

      body_lines = [io_init, parent_init, body, io_pos_code]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      # Insert io_pos updates before each field that references _io
      body_lines = if needs_io do
        insert_io_pos_updates(body_lines)
      else
        body_lines
      end

      parse_args = if has_params do
        Enum.join(["data", "root_", "parent_"] ++ param_names, ", ")
      else
        "data, root_, parent_ \\\\ nil"
      end

      """
      def parse(#{parse_args}) do
        rest = data
      #{Utils.indent(body_lines, 1)}
        {%{#{result_map}}, rest}
      end
      """
      |> String.trim()
    end
  end

  # Group attrs into runs of consecutive bit fields vs non-bit fields, producing code
  defp compile_attr_parses_with_bits(attrs, endian, type_registry, spec, bit_endian) do
    # Group into runs: {:bit, [attrs]} or {:normal, attr}
    groups = group_bit_runs(attrs, endian, type_registry, spec)

    needs_parent = Enum.any?(attrs, fn attr ->
      is_user_type_attr?(attr, endian, type_registry, spec)
    end)

    Enum.map(groups, fn
      {:normal, attr} ->
        code = compile_attr_parse(attr, endian, type_registry, spec)
        if needs_parent do
          code <> "\nresult_so_far = Map.put(result_so_far, :#{attr.id}, var_#{attr.id})"
        else
          code
        end

      {:bit_run, bit_attrs} ->
        # Generate code that uses bit accumulator state
        bit_fn = if bit_endian == "le", do: "read_bits_le", else: "read_bits_be"
        init_code = "bits_state = {0, 0, rest}"
        field_codes = Enum.map(bit_attrs, fn attr ->
          var = "var_#{attr.id}"
          {_match, {:bit, bit_size}} = type_to_pattern(attr.type, endian, attr, type_registry, spec)

          read_code = "{#{var}, bits_state} = Ksc.Stream.#{bit_fn}(bits_state, #{bit_size})"

          # b1 yields boolean (unless enum is applied)
          read_code = if bit_size == 1 and attr.enum == nil do
            read_code <> "\n#{var} = #{var} != 0"
          else
            read_code
          end

          # Wrap in conditional if needed
          if attr.if_expr != nil do
            condition = translate_expr(attr.if_expr)
            """
            {#{var}, bits_state} = if #{condition} do
              #{read_code}
              {#{var}, bits_state}
            else
              {nil, bits_state}
            end
            """
            |> String.trim()
          else
            maybe_wrap_enum(read_code, attr, var)
          end
        end)
        align_code = "rest = Ksc.Stream.align_to_byte(bits_state)"
        parent_updates = if needs_parent do
          Enum.map(bit_attrs, fn attr ->
            "result_so_far = Map.put(result_so_far, :#{attr.id}, var_#{attr.id})"
          end)
        else
          []
        end
        Enum.join([init_code | field_codes] ++ [align_code] ++ parent_updates, "\n")
    end)
  end

  defp group_bit_runs(attrs, endian, type_registry, spec) do
    {groups, current_bits} = Enum.reduce(attrs, {[], []}, fn attr, {groups, current_bits} ->
      if is_bit_type?(attr, endian, type_registry, spec) do
        {groups, current_bits ++ [attr]}
      else
        if current_bits != [] do
          {groups ++ [{:bit_run, current_bits}, {:normal, attr}], []}
        else
          {groups ++ [{:normal, attr}], []}
        end
      end
    end)

    if current_bits != [] do
      groups ++ [{:bit_run, current_bits}]
    else
      groups
    end
  end

  defp is_user_type_attr?(%AttrSpec{} = attr, endian, type_registry, spec) do
    case type_to_pattern(attr.type, endian, attr, type_registry, spec) do
      {_, :user_type} -> true
      {_, :switch} -> true  # switch may contain user types
      _ -> false
    end
  end

  defp is_bit_type?(%AttrSpec{} = attr, endian, type_registry, spec) do
    case type_to_pattern(attr.type, endian, attr, type_registry, spec) do
      {_, {:bit, _}} -> true
      _ -> false
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
        {base_type, type_args} = parse_type_args(attr.type)
        type_mod = resolve_type_module(base_type, type_registry, spec)
        # Build result map reference for parent passing
        parent_ref = "result_so_far"
        # Translate type arguments
        args_str = if type_args != [] do
          ", " <> Enum.map_join(type_args, ", ", &translate_expr/1)
        else
          ""
        end
        cond do
          attr.size != nil ->
            # Sized user type: extract substream, apply processing, then parse
            size_expr = translate_expr(attr.size)
            extract = """
            size_#{attr.id} = #{size_expr}
            <<#{var}_data::binary-size(size_#{attr.id}), rest::binary>> = rest
            """
            |> String.trim()
            # Apply pad/term/process to extracted data before parsing
            processing = build_data_processing(attr, "#{var}_data")
            parse_line = "{#{var}, _} = #{type_mod}.parse(#{var}_data, root_, #{parent_ref}#{args_str})"
            Enum.join([extract | processing] ++ [parse_line], "\n")

          attr.terminator != nil ->
            # User type with terminator: read until terminator, then parse substream
            consume = if attr.consume == false, do: "false", else: "true"
            include = if attr.include == true, do: "true", else: "false"
            """
            {#{var}_data, rest} = Ksc.Stream.read_terminated(rest, #{attr.terminator}, #{consume}, #{include})
            {#{var}, _} = #{type_mod}.parse(#{var}_data, root_, #{parent_ref}#{args_str})
            """
            |> String.trim()

          attr.size_eos == true ->
            """
            {#{var}, _} = #{type_mod}.parse(rest, root_, #{parent_ref}#{args_str})
            rest = <<>>
            """
            |> String.trim()

          true ->
            "{#{var}, rest} = #{type_mod}.parse(rest, root_, #{parent_ref}#{args_str})"
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
        encoding = resolve_encoding(attr, spec)
        code = "size_#{attr.id} = #{size_expr}\n<<#{var}::binary-size(size_#{attr.id}), rest::binary>> = rest"
        code = maybe_apply_byte_processing(code, attr, var)
        maybe_apply_encoding(code, encoding, var)

      :str_eos ->
        encoding = resolve_encoding(attr, spec)
        code = "#{var} = rest\nrest = <<>>"
        code = maybe_apply_byte_processing(code, attr, var)
        maybe_apply_encoding(code, encoding, var)

      :strz ->
        encoding = resolve_encoding(attr, spec)
        consume = if attr.consume == false, do: "false", else: "true"
        if encoding && String.upcase(encoding) in ["UTF-16LE", "UTF-16BE"] do
          "{#{var}, rest} = Ksc.Stream.read_strz_enc(rest, \"#{encoding}\", #{consume})"
        else
          code = if attr.consume == false do
            "{#{var}, rest} = Ksc.Stream.read_strz_consume(rest, #{consume})"
          else
            "{#{var}, rest} = Ksc.Stream.read_strz(rest)"
          end
          maybe_apply_encoding(code, encoding, var)
        end

      :terminated ->
        # Field with terminator but no size - scan for terminator
        consume = if attr.consume == false, do: "false", else: "true"
        include = if attr.include == true, do: "true", else: "false"
        encoding = resolve_encoding(attr, spec)
        code = "{#{var}, rest} = Ksc.Stream.read_terminated(rest, #{attr.terminator}, #{consume}, #{include})"
        maybe_apply_encoding(code, encoding, var)

      {:bit, size} ->
        code = "{#{var}, rest} = Ksc.Stream.read_bits(rest, #{size})"
        if size == 1 do
          code <> "\n#{var} = #{var} != 0"
        else
          code
        end

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
    {#{var}, rest} = Enum.reduce(Enum.with_index(1..max(#{count}, 0)//1), {[], rest}, fn {_, var__index}, {acc, rest} ->
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
    # Topological sort: resolve instances in dependency order
    sorted_instances = topological_sort_instances(instances)

    assignments =
      Enum.map(sorted_instances, fn {name, %InstanceSpec{} = inst} ->
        code = cond do
          inst.value != nil ->
            expr = translate_expr_for_instance(inst.value)
            "result = Map.put(result, :#{name}, #{expr})"

          inst.pos != nil ->
            pos_expr = translate_expr_for_instance(inst.pos)
            compile_parse_instance(name, inst, pos_expr, endian, type_registry, spec)

          inst.type != nil and inst.size != nil ->
            size_expr = translate_expr_for_instance(inst.size)
            compile_sized_parse_instance(name, inst, size_expr, endian, type_registry, spec)

          inst.type != nil and inst.size_eos == true ->
            # Type with size-eos: parse from current data
            type_mod = resolve_type_module(inst.type, type_registry, spec)
            """
            {inst_val, _} = #{type_mod}.parse(root_data, result)
            result = Map.put(result, :#{name}, inst_val)
            """
            |> String.trim()

          true ->
            nil
        end

        # Wrap in conditional if needed
        if code != nil and inst.if_expr != nil do
          condition = translate_expr_for_instance(inst.if_expr)
          """
          result = if #{condition} do
            #{code}
            result
          else
            Map.put(result, :#{name}, nil)
          end
          """
          |> String.trim()
        else
          code
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
    # Determine how much to read
    data_expr = if inst.size != nil do
      size_expr = translate_expr_for_instance(inst.size)
      "binary_part(root_data, #{pos_expr}, #{size_expr})"
    else
      "binary_part(root_data, #{pos_expr}, byte_size(root_data) - #{pos_expr})"
    end

    if inst.type == nil do
      # No type - just read bytes
      """
      inst_val = #{data_expr}
      result = Map.put(result, :#{name}, inst_val)
      """
      |> String.trim()
    else
      {_match, type_info} = type_to_pattern(inst.type, endian, %AttrSpec{size: inst.size, size_eos: inst.size_eos}, type_registry, spec)

      case type_info do
        :user_type ->
          type_mod = resolve_type_module(inst.type, type_registry, spec)
          if has_instances_for_type?(inst.type, spec) do
            """
            inst_data = #{data_expr}
            {inst_val, _} = #{type_mod}.parse(inst_data, result)
            inst_val = #{type_mod}.resolve_instances(inst_val, inst_data)
            result = Map.put(result, :#{name}, inst_val)
            """
            |> String.trim()
          else
            """
            inst_data = #{data_expr}
            {inst_val, _} = #{type_mod}.parse(inst_data, result)
            result = Map.put(result, :#{name}, inst_val)
            """
            |> String.trim()
          end

        :primitive ->
          {match, _} = type_to_pattern(inst.type, endian, %AttrSpec{}, type_registry, spec)
          """
          inst_data = #{data_expr}
          <<inst_val::#{match}, _::binary>> = inst_data
          #{maybe_wrap_enum_inst(inst, "inst_val")}
          result = Map.put(result, :#{name}, inst_val)
          """
          |> String.trim()

        :str ->
          """
          inst_val = #{data_expr}
          result = Map.put(result, :#{name}, inst_val)
          """
          |> String.trim()

        :str_eos ->
          """
          inst_val = #{data_expr}
          result = Map.put(result, :#{name}, inst_val)
          """
          |> String.trim()

        :bytes ->
          """
          inst_val = #{data_expr}
          result = Map.put(result, :#{name}, inst_val)
          """
          |> String.trim()

        _ ->
          """
          inst_val = #{data_expr}
          result = Map.put(result, :#{name}, inst_val)
          """
          |> String.trim()
      end
    end
  end

  defp has_instances_for_type?(type_name, spec) when is_binary(type_name) do
    case Map.get(spec.types, type_name) do
      %ClassSpec{instances: instances} when map_size(instances) > 0 -> true
      _ -> false
    end
  end

  defp maybe_wrap_enum_inst(%InstanceSpec{enum: nil}, _var), do: ""
  defp maybe_wrap_enum_inst(%InstanceSpec{enum: enum_name}, var) do
    if String.contains?(enum_name, "::") do
      parts = String.split(enum_name, "::")
      enum_id = List.last(parts)
      "#{var} = Map.get(@enum_#{enum_id}, #{var}, #{var})"
    else
      "#{var} = Map.get(@enum_#{enum_name}, #{var}, #{var})"
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
        {inst_val, _} = #{type_mod}.parse(inst_data, result)
        result = Map.put(result, :#{name}, inst_val)
        """
        |> String.trim()

      :primitive ->
        {match, _} = type_to_pattern(inst.type, endian, %AttrSpec{}, type_registry, spec)
        """
        <<inst_val::#{match}, _::binary>> = root_data
        result = Map.put(result, :#{name}, inst_val)
        """
        |> String.trim()

      _ ->
        """
        inst_size = #{size_expr}
        <<inst_val::binary-size(inst_size), _::binary>> = root_data
        result = Map.put(result, :#{name}, inst_val)
        """
        |> String.trim()
    end
  end

  defp type_to_pattern(nil, _endian, attr, _type_registry, _spec) do
    cond do
      attr.size != nil -> {"", :bytes}
      attr.size_eos == true and Map.get(attr, :terminator) != nil -> {"", :bytes_eos}
      attr.size_eos == true -> {"", :bytes_eos}
      Map.get(attr, :terminator) != nil -> {"", :terminated}
      true -> {"binary", :raw}
    end
  end

  defp type_to_pattern(type, endian, attr, type_registry, spec) when is_binary(type) do
    # Strip type args for pattern matching
    {base_type, _args} = parse_type_args(type)

    cond do
      # Bit types: b1 through b64
      Regex.match?(~r/^b\d+$/, base_type) ->
        bit_size = String.trim_leading(base_type, "b") |> String.to_integer()
        {"", {:bit, bit_size}}

      true ->
        case base_type do
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
    # Strip args from type reference
    {base_type, _args} = parse_type_args(type)
    # Handle :: path separator (e.g., "subtype_a::subtype_cc")
    if String.contains?(base_type, "::") do
      true
    else
      # Check local types, type registry, and imports
      Map.has_key?(type_registry, base_type) or
        Map.has_key?(spec.types, base_type) or
        base_type in (spec.imports || []) or
        Enum.any?(spec.imports || [], fn imp ->
          # Import could be "common/vlq" but type ref is just "vlq_base128_le"
          String.ends_with?(imp, "/#{base_type}") or imp == base_type
        end)
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
      type_path = Enum.slice(parts, 0..-2//1) |> Enum.map(&Utils.to_module_name/1) |> Enum.join(".")
      enum_id = List.last(parts)
      # Reference the enum in the specific type module
      code <> "\n#{var} = Map.get(#{type_path}.enum_#{enum_id}(), #{var}, #{var})"
    else
      code <> "\n#{var} = Map.get(@enum_#{enum_name}, #{var}, #{var})"
    end
  end

  defp maybe_apply_byte_processing(code, %AttrSpec{} = attr, var) do
    # KSY spec order: strip pad_right first, then apply terminator
    code =
      if attr.pad_right != nil do
        code <> "\n#{var} = Ksc.Stream.strip_pad_right(#{var}, #{attr.pad_right})"
      else
        code
      end

    code =
      if attr.terminator != nil do
        code <> "\n#{var} = Ksc.Stream.terminate_at(#{var}, #{attr.terminator}, #{attr.include == true})"
      else
        code
      end

    maybe_apply_process(code, attr, var)
  end

  defp maybe_apply_process(code, %AttrSpec{process: nil}, _var), do: code

  defp maybe_apply_process(code, %AttrSpec{process: process}, var) when is_binary(process) do
    cond do
      # process: xor(key) where key is integer
      Regex.match?(~r/^xor\(/, process) ->
        arg = String.trim_leading(process, "xor(") |> String.trim_trailing(")")
        # Check if the arg is a field reference or a literal
        cond do
          # Byte array literal like [0xec, 0xbb, ...]
          String.starts_with?(arg, "[") ->
            code <> "\n#{var} = Ksc.Stream.process_xor(#{var}, #{translate_expr(arg)})"
          # Hex or int literal
          String.starts_with?(arg, "0x") or Regex.match?(~r/^\d+$/, arg) ->
            code <> "\n#{var} = Ksc.Stream.process_xor(#{var}, #{arg})"
          true ->
            # Field reference
            code <> "\n#{var} = Ksc.Stream.process_xor(#{var}, #{translate_expr(arg)})"
        end

      process == "zlib" ->
        code <> "\n#{var} = Ksc.Stream.process_zlib(#{var})"

      Regex.match?(~r/^rotate_left\(/, process) ->
        arg = String.trim_leading(process, "rotate_left(") |> String.trim_trailing(")")
        code <> "\n#{var} = Ksc.Stream.process_rotate_left(#{var}, #{translate_expr(arg)})"

      Regex.match?(~r/^rol\(/, process) ->
        arg = String.trim_leading(process, "rol(") |> String.trim_trailing(")")
        code <> "\n#{var} = Ksc.Stream.process_rotate_left(#{var}, #{translate_expr(arg)})"

      Regex.match?(~r/^ror\(/, process) ->
        arg = String.trim_leading(process, "ror(") |> String.trim_trailing(")")
        code <> "\n#{var} = Ksc.Stream.process_rotate_left(#{var}, 8 - #{translate_expr(arg)})"

      true ->
        # Unknown process, just pass through
        code
    end
  end

  defp maybe_apply_process(code, _attr, _var), do: code

  defp compile_enums(enums) when map_size(enums) == 0, do: ""

  defp compile_enums(enums) do
    Enum.map(enums, fn {name, %{values: values}} ->
      map_str =
        Enum.map(values, fn {k, v} -> "#{k} => :#{v}" end)
        |> Enum.join(", ")

      "@enum_#{name} %{#{map_str}}\ndef enum_#{name}(), do: @enum_#{name}"
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

  defp collect_all_expressions(attrs) do
    Enum.flat_map(attrs, fn %AttrSpec{} = a ->
      [a.size, a.if_expr, a.repeat_expr, a.repeat_until] |> Enum.reject(&is_nil/1)
    end)
  end

  defp insert_io_pos_updates(body) do
    # Insert io_pos = io_size - byte_size(rest) before lines that use io_pos
    lines = String.split(body, "\n")
    Enum.flat_map(lines, fn line ->
      if String.contains?(line, "io_pos") and not String.starts_with?(String.trim(line), "io_pos =") and not String.starts_with?(String.trim(line), "io_size =") do
        ["io_pos = io_size - byte_size(rest)", line]
      else
        [line]
      end
    end)
    |> Enum.join("\n")
  end

  # Parse type reference with optional arguments: "my_type(arg1, arg2)" -> {"my_type", ["arg1", "arg2"]}
  defp parse_type_args(type) when is_binary(type) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_:]*)\((.+)\)$/, type) do
      [_, base_type, args_str] ->
        args = split_args(args_str)
        {base_type, args}
      nil ->
        {type, []}
    end
  end
  defp parse_type_args(type), do: {type, []}

  defp split_args(str) do
    # Split on commas outside of parentheses
    chars = String.graphemes(str)
    {args, current, _depth} = Enum.reduce(chars, {[], "", 0}, fn ch, {args, current, depth} ->
      case ch do
        "(" -> {args, current <> ch, depth + 1}
        ")" -> {args, current <> ch, depth - 1}
        "," when depth == 0 -> {args ++ [String.trim(current)], "", 0}
        _ -> {args, current <> ch, depth}
      end
    end)
    args ++ [String.trim(current)]
  end

  # Build processing steps for data variable (pad, term, process)
  defp build_data_processing(%AttrSpec{} = attr, data_var) do
    steps = []
    steps = if attr.pad_right != nil do
      steps ++ ["#{data_var} = Ksc.Stream.strip_pad_right(#{data_var}, #{attr.pad_right})"]
    else
      steps
    end
    steps = if attr.terminator != nil do
      steps ++ ["#{data_var} = Ksc.Stream.terminate_at(#{data_var}, #{attr.terminator}, #{attr.include == true})"]
    else
      steps
    end
    steps = if attr.process != nil do
      steps ++ [build_process_step(attr.process, data_var)]
    else
      steps
    end
    steps
  end

  defp build_process_step(process, var) when is_binary(process) do
    cond do
      Regex.match?(~r/^xor\(/, process) ->
        arg = String.trim_leading(process, "xor(") |> String.trim_trailing(")")
        cond do
          String.starts_with?(arg, "[") ->
            "#{var} = Ksc.Stream.process_xor(#{var}, #{translate_expr(arg)})"
          String.starts_with?(arg, "0x") or Regex.match?(~r/^\d+$/, arg) ->
            "#{var} = Ksc.Stream.process_xor(#{var}, #{arg})"
          true ->
            "#{var} = Ksc.Stream.process_xor(#{var}, #{translate_expr(arg)})"
        end
      process == "zlib" ->
        "#{var} = Ksc.Stream.process_zlib(#{var})"
      Regex.match?(~r/^rotate_left\(/, process) ->
        arg = String.trim_leading(process, "rotate_left(") |> String.trim_trailing(")")
        "#{var} = Ksc.Stream.process_rotate_left(#{var}, #{translate_expr(arg)})"
      Regex.match?(~r/^rol\(/, process) ->
        arg = String.trim_leading(process, "rol(") |> String.trim_trailing(")")
        "#{var} = Ksc.Stream.process_rotate_left(#{var}, #{translate_expr(arg)})"
      Regex.match?(~r/^ror\(/, process) ->
        arg = String.trim_leading(process, "ror(") |> String.trim_trailing(")")
        "#{var} = Ksc.Stream.process_rotate_left(#{var}, 8 - #{translate_expr(arg)})"
      true ->
        "# unknown process: #{process}"
    end
  end

  defp topological_sort_instances(instances) do
    names = Map.keys(instances)
    # Build dependency graph
    deps = Map.new(instances, fn {name, inst} ->
      expr_text = Enum.join([
        inst.value || "",
        inst.if_expr || "",
        inst.pos || "",
        inst.size || "",
        inst.io || ""
      ], " ")
      referenced = Enum.filter(names, fn other ->
        other != name and String.contains?(expr_text, other)
      end)
      {name, referenced}
    end)

    # Kahn's algorithm
    sorted = topological_sort_kahn(names, deps)
    Enum.map(sorted, fn name -> {name, instances[name]} end)
  end

  defp topological_sort_kahn(names, deps) do
    # in_degree: count how many deps each node has
    in_degree = Map.new(names, fn n -> {n, length(Map.get(deps, n, []))} end)
    queue = Enum.filter(names, fn n -> Map.get(in_degree, n, 0) == 0 end) |> :queue.from_list()
    do_topological_sort(queue, deps, in_degree, names, [])
  end

  defp do_topological_sort(queue, deps, in_degree, all_names, result) do
    case :queue.out(queue) do
      {:empty, _} ->
        # Add any remaining nodes (cycle handling)
        remaining = all_names -- result
        result ++ remaining

      {{:value, node}, queue} ->
        result = result ++ [node]
        # Find nodes that depend on this one
        dependents = Enum.filter(all_names, fn n ->
          n not in result and node in Map.get(deps, n, [])
        end)
        {queue, in_degree} = Enum.reduce(dependents, {queue, in_degree}, fn dep, {q, id} ->
          new_degree = Map.get(id, dep, 0) - 1
          id = Map.put(id, dep, new_degree)
          if new_degree == 0 do
            {:queue.in(dep, q), id}
          else
            {q, id}
          end
        end)
        do_topological_sort(queue, deps, in_degree, all_names, result)
    end
  end

  defp resolve_encoding(%AttrSpec{encoding: enc}, _spec) when is_binary(enc) and enc != "", do: enc
  defp resolve_encoding(_attr, %ClassSpec{encoding: enc}) when is_binary(enc) and enc != "", do: enc
  defp resolve_encoding(_, _), do: nil

  defp maybe_apply_encoding(code, nil, _var), do: code
  defp maybe_apply_encoding(code, "UTF-8", _var), do: code
  defp maybe_apply_encoding(code, "ASCII", _var), do: code
  defp maybe_apply_encoding(code, encoding, var) do
    code <> "\n#{var} = Ksc.Stream.decode_string(#{var}, \"#{encoding}\")"
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
