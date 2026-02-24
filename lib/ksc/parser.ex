defmodule Ksc.Parser do
  @moduledoc "Parses KSY YAML into internal format structs."

  alias Ksc.Format.{ClassSpec, AttrSpec, InstanceSpec, EnumSpec}

  def parse_file(path) do
    Ksc.Yaml.parse_file(path) |> parse_class()
  end

  def parse_string(yaml_string) do
    Ksc.Yaml.parse_string(yaml_string) |> parse_class()
  end

  def parse_class(nil), do: %ClassSpec{}

  def parse_class(map) when is_map(map) do
    meta = Map.get(map, "meta", %{}) || %{}

    %ClassSpec{
      id: Map.get(meta, "id"),
      endian: parse_endian(Map.get(meta, "endian")),
      bit_endian: Map.get(meta, "bit-endian"),
      encoding: Map.get(meta, "encoding"),
      seq: parse_seq(Map.get(map, "seq", [])),
      types: parse_types(Map.get(map, "types", %{})),
      instances: parse_instances(Map.get(map, "instances", %{})),
      enums: parse_enums(Map.get(map, "enums", %{})),
      imports: Map.get(meta, "imports", []) || [],
      params: parse_params(Map.get(map, "params"))
    }
  end

  defp parse_endian("le"), do: :le
  defp parse_endian("be"), do: :be
  defp parse_endian(%{"switch-on" => switch_on, "cases" => cases}) do
    parsed_cases = Enum.map(cases || %{}, fn {k, v} ->
      {to_string(k), parse_endian(v)}
    end) |> Map.new()
    {:switch, to_string(switch_on), parsed_cases}
  end
  defp parse_endian(_), do: nil

  defp parse_seq(nil), do: []

  defp parse_seq(list) when is_list(list) do
    Enum.map(list, &parse_attr/1)
  end

  def parse_attr(map) when is_map(map) do
    %AttrSpec{
      id: Map.get(map, "id"),
      type: parse_type_ref(Map.get(map, "type")),
      size: stringify_expr(Map.get(map, "size")),
      size_eos: Map.get(map, "size-eos"),
      encoding: Map.get(map, "encoding"),
      enum: Map.get(map, "enum"),
      contents: parse_contents(Map.get(map, "contents")),
      if_expr: stringify_expr(Map.get(map, "if")),
      repeat: Map.get(map, "repeat"),
      repeat_expr: stringify_expr(Map.get(map, "repeat-expr")),
      repeat_until: stringify_expr(Map.get(map, "repeat-until")),
      terminator: Map.get(map, "terminator"),
      pad_right: Map.get(map, "pad-right"),
      include: Map.get(map, "include"),
      process: Map.get(map, "process"),
      consume: Map.get(map, "consume"),
      eos_error: Map.get(map, "eos-error"),
      parent: Map.get(map, "parent")
    }
  end

  defp parse_type_ref(nil), do: nil

  defp parse_type_ref(map) when is_map(map) do
    # switch-on type
    %{
      "switch-on" => stringify_expr(Map.get(map, "switch-on")),
      "cases" => Map.get(map, "cases", %{}) |> Enum.map(fn {k, v} ->
        {stringify_expr(k), parse_type_ref(v)}
      end) |> Map.new()
    }
  end

  defp parse_type_ref(str) when is_binary(str), do: str
  defp parse_type_ref(val), do: to_string(val)

  defp stringify_expr(nil), do: nil
  defp stringify_expr(val) when is_binary(val), do: val
  defp stringify_expr(val) when is_integer(val), do: to_string(val)
  defp stringify_expr(val) when is_float(val), do: to_string(val)
  defp stringify_expr(val) when is_boolean(val), do: to_string(val)
  defp stringify_expr(val) when is_list(val), do: inspect(val)
  defp stringify_expr(val) when is_map(val), do: inspect(val)

  defp parse_contents(nil), do: nil

  defp parse_contents(str) when is_binary(str) do
    :binary.bin_to_list(str)
  end

  defp parse_contents(list) when is_list(list) do
    Enum.map(list, fn
      val when is_integer(val) -> val
      val when is_binary(val) -> parse_scalar_int(val)
    end)
  end

  defp parse_scalar_int(str) do
    cond do
      String.starts_with?(str, "0x") ->
        {val, _} = Integer.parse(String.trim_leading(str, "0x"), 16)
        val
      true ->
        String.to_integer(str)
    end
  end

  defp parse_types(nil), do: %{}

  defp parse_types(map) when is_map(map) do
    Enum.map(map, fn {name, type_map} ->
      spec = parse_class(type_map)
      # If no meta.id, use the type name from the parent types: map
      spec = if spec.id == nil, do: %{spec | id: name}, else: spec
      {name, spec}
    end)
    |> Map.new()
  end

  defp parse_instances(nil), do: %{}

  defp parse_instances(map) when is_map(map) do
    Enum.map(map, fn {name, inst_map} ->
      {name, parse_instance(name, inst_map)}
    end)
    |> Map.new()
  end

  defp parse_instance(name, val) when not is_map(val) do
    %InstanceSpec{id: name, value: stringify_expr(val)}
  end

  defp parse_instance(name, map) when is_map(map) do
    %InstanceSpec{
      id: name,
      value: stringify_expr(Map.get(map, "value")),
      type: parse_type_ref(Map.get(map, "type")),
      pos: stringify_expr(Map.get(map, "pos")),
      io: stringify_expr(Map.get(map, "io")),
      size: stringify_expr(Map.get(map, "size")),
      size_eos: Map.get(map, "size-eos"),
      encoding: Map.get(map, "encoding"),
      enum: Map.get(map, "enum"),
      if_expr: stringify_expr(Map.get(map, "if")),
      repeat: Map.get(map, "repeat"),
      repeat_expr: stringify_expr(Map.get(map, "repeat-expr")),
      repeat_until: stringify_expr(Map.get(map, "repeat-until")),
      terminator: Map.get(map, "terminator"),
      pad_right: Map.get(map, "pad-right"),
      include: Map.get(map, "include")
    }
  end

  defp parse_params(nil), do: []
  defp parse_params(list) when is_list(list) do
    Enum.map(list, fn param ->
      %{
        id: Map.get(param, "id"),
        type: Map.get(param, "type"),
        enum: Map.get(param, "enum")
      }
    end)
  end

  defp parse_enums(nil), do: %{}

  defp parse_enums(map) when is_map(map) do
    Enum.map(map, fn {name, values_map} ->
      values =
        Enum.map(values_map, fn {k, v} ->
          key = if is_integer(k), do: k, else: parse_enum_key(to_string(k))
          val = case v do
            v when is_binary(v) -> String.to_atom(v)
            v when is_map(v) -> String.to_atom(Map.get(v, "id", to_string(k)))
            v when is_atom(v) -> v
            _ -> v
          end
          {key, val}
        end)
        |> Map.new()

      {name, %EnumSpec{id: name, values: values}}
    end)
    |> Map.new()
  end

  defp parse_enum_key(str) do
    cond do
      String.starts_with?(str, "0x") ->
        {val, _} = Integer.parse(String.trim_leading(str, "0x"), 16)
        val
      true ->
        String.to_integer(str)
    end
  end
end
