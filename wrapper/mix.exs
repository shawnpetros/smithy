defmodule Smithy.MixProject do
  use Mix.Project

  def project do
    [
      app: :smithy,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl, :crypto, :eex]]
  end

  defp deps do
    [
      {:toml, "~> 0.7"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"]
    ]
  end

  defp escript do
    [
      main_module: Smithy.CLI,
      name: "smithy",
      path: "bin/smithy",
      app: nil
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
