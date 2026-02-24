defmodule Ksc.Yaml do
  @moduledoc """
  YAML parser for KSY files. Delegates to yaml_elixir and normalizes keys to strings.
  """

  def parse_file(path) do
    path |> File.read!() |> parse_string()
  end

  def parse_string(string) do
    case YamlElixir.read_from_string(string) do
      {:ok, result} -> normalize(result)
      {:error, _} -> nil
    end
  end

  # Normalize all map keys to strings (yaml_elixir may return string keys already, but be safe)
  defp normalize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize(v)} end)
  end

  defp normalize(list) when is_list(list) do
    Enum.map(list, &normalize/1)
  end

  defp normalize(other), do: other
end
