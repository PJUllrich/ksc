defmodule Ksc.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/PJUllrich/ksc"

  def project do
    [
      app: :ksc,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Ksc",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:yaml_elixir, "~> 2.12"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    An Elixir implementation of the Kaitai Struct compiler and runtime.
    Compiles .ksy format descriptions into Elixir modules that parse binary data into structured maps.
    """
  end

  defp package do
    [
      maintainers: ["Peter Ullrich"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"]
    ]
  end
end
