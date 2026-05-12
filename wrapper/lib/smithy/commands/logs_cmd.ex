defmodule Smithy.Commands.LogsCmd do
  @moduledoc """
  Handler for `smithy logs <slug> [--follow]`.
  """

  alias Smithy.{Config, Logs, RepoRegistry}

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          print: (String.t(), boolean() -> :ok | {:error, term()})
        }

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([slug], opts, deps) do
    follow? = Map.get(opts, :follow, false)

    with {:ok, config} <- deps.load.(),
         {:ok, _repo} <- RepoRegistry.fetch(config, slug),
         :ok <- deps.print.(slug, follow?) do
      {:ok, ""}
    end
  end

  def run(_, _, _), do: {:error, :usage}

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      print: fn slug, follow? -> Logs.print(slug, follow?, :stdio) end
    }
  end
end
