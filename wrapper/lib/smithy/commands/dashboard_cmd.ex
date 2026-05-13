defmodule Smithy.Commands.DashboardCmd do
  @moduledoc """
  Handler for `smithy dashboard [slug]`.

  With no slug: generates a real aggregate HTML dashboard at
  `~/.smithy/dashboard.html`, opens it in the browser, then loops
  every 5 s rewriting the file so the page's auto-refresh picks up
  fresh daemon state. Stays running until Ctrl-C.

  With a slug: opens the repo's Symphony LiveView directly.
  """

  alias Smithy.{Config, Dashboard, RepoRegistry}

  @refresh_ms 5_000

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          open: (String.t() -> {:ok, String.t()} | {:error, term()}),
          write_dashboard: (Config.t() -> {:ok, String.t()} | {:error, term()}),
          sleep: (non_neg_integer() -> :ok)
        }

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([], _opts, deps) do
    with {:ok, config} <- deps.load.(),
         {:ok, path} <- deps.write_dashboard.(config),
         {:ok, _} <- deps.open.("file://" <> path) do
      IO.puts("Smithy dashboard running at file://#{path}")
      IO.puts("Refreshing every #{div(@refresh_ms, 1000)} s -- Ctrl-C to stop")
      refresh_loop(path, deps)
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

  defp refresh_loop(path, deps) do
    deps.sleep.(@refresh_ms)

    case deps.load.() do
      {:ok, config} -> deps.write_dashboard.(config)
      _ -> :ok
    end

    refresh_loop(path, deps)
  end

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      open: fn target -> Dashboard.open(target) end,
      write_dashboard: fn config -> Dashboard.write_aggregate_html(config) end,
      sleep: fn ms -> Process.sleep(ms) end
    }
  end
end
