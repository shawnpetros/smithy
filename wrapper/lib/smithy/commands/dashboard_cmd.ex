defmodule Smithy.Commands.DashboardCmd do
  @moduledoc """
  Handler for `smithy dashboard [slug]`.
  """

  alias Smithy.{Config, Dashboard, RepoRegistry}

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          open: (String.t() -> {:ok, String.t()} | {:error, term()}),
          write_dashboard: (Config.t() -> {:ok, String.t()} | {:error, term()})
        }

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([], _opts, deps) do
    with {:ok, config} <- deps.load.(),
         {:ok, path} <- deps.write_dashboard.(config),
         {:ok, _} <- deps.open.("file://" <> path) do
      {:ok, "opened aggregate dashboard at #{path}"}
    end
  end

  def run([slug], _opts, deps) do
    with {:ok, config} <- deps.load.(),
         {:ok, repo} <- RepoRegistry.fetch(config, slug),
         {:ok, _} <- deps.open.("http://localhost:#{repo.port}/") do
      {:ok, "opened http://localhost:#{repo.port}/"}
    end
  end

  def run(_, _, _), do: {:error, :usage}

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      open: fn target -> Dashboard.open(target) end,
      write_dashboard: fn config -> Dashboard.write_aggregate_html(config) end
    }
  end
end
