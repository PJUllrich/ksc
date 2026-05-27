defmodule Ksc.Compiler.Utils do
  @moduledoc "Name conversion and code generation helpers."

  @doc "Convert snake_case id to CamelCase module name."
  def to_module_name(id) when is_binary(id) do
    id
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  def to_module_name(_), do: "Unknown"

  @doc "Ensure a field name is a valid Elixir atom-safe identifier."
  def to_field_name(id) when is_binary(id) do
    String.to_atom(id)
  end

  @doc "Indent a block of code by the given number of spaces."
  def indent(code, level) when is_binary(code) and is_integer(level) do
    prefix = String.duplicate("  ", level)

    code
    |> String.split("\n")
    |> Enum.map(fn
      "" -> ""
      line -> prefix <> line
    end)
    |> Enum.join("\n")
  end

  @doc "Join code blocks with double newlines."
  def join_code(blocks) do
    blocks
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.join("\n\n")
  end
end
