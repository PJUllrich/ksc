defmodule Mix.Tasks.Ksc.Compile do
  @moduledoc """
  Compiles .ksy files to Elixir source files.

      mix ksc.compile <input_path> --output <output_dir> [--namespace <namespace>]

  `input_path` is a single `.ksy` file or a directory containing `.ksy` files.
  `--output` specifies the directory where `.ex` files are written (created if needed).
  `--namespace` sets the module namespace prefix (default: `Ksc.Compiled`).
  """

  use Mix.Task

  @shortdoc "Compile .ksy files to .ex files"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [output: :string, namespace: :string])

    input_path =
      case positional do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix ksc.compile <input_path> --output <output_dir>")
      end

    output_dir =
      opts[:output] || Mix.raise("Usage: mix ksc.compile <input_path> --output <output_dir>")

    compile_opts =
      case opts[:namespace] do
        nil -> []
        ns -> [namespace: ns]
      end

    case Ksc.compile_to_files(input_path, output_dir, compile_opts) do
      {:ok, files} ->
        Enum.each(files, &Mix.shell().info("Written: #{&1}"))
        Mix.shell().info("Compiled #{length(files)} file(s) to #{output_dir}")

      {:error, reason} ->
        Mix.raise("Compilation failed: #{reason}")
    end
  end
end
