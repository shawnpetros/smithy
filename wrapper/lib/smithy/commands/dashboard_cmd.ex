defmodule Smithy.Commands.DashboardCmd do
  @moduledoc """
  Handler for `smithy dashboard [slug]`.

  With no slug: generates a real aggregate HTML dashboard at
  `~/.smithy/dashboard.html`, opens it in the browser, then loops
  every 5 s rewriting the file so the page's auto-refresh picks up
  fresh daemon state. Stays running until Ctrl-C.

  With a slug: opens the repo's Symphony LiveView directly.
  """

  alias Smithy.{Config, Dashboard, RepoRegistry, Status}

  @refresh_ms 5_000

  @type sample :: {integer(), non_neg_integer()} | nil

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          open: (String.t() -> {:ok, String.t()} | {:error, term()}),
          collect: (Config.t() -> Status.aggregate()),
          write_html: (Config.t(), Status.aggregate() -> {:ok, String.t()} | {:error, term()}),
          sleep: (non_neg_integer() -> :ok),
          monotonic_ms: (-> integer())
        }

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([], _opts, deps) do
    with {:ok, config} <- deps.load.(),
         now_ms <- deps.monotonic_ms.(),
         aggregate <- deps.collect.(config),
         aggregate <- inject_throughput(nil, aggregate, now_ms),
         {:ok, path} <- deps.write_html.(config, aggregate),
         {:ok, _} <- deps.open.("file://" <> path) do
      IO.puts("Smithy dashboard running at file://#{path}")
      IO.puts("Refreshing every #{div(@refresh_ms, 1000)} s -- Ctrl-C to stop")
      initial_sample = {now_ms, tokens_total(aggregate)}
      refresh_loop(path, config, initial_sample, deps)
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

  defp refresh_loop(path, config, previous_sample, deps) do
    deps.sleep.(@refresh_ms)
    now_ms = deps.monotonic_ms.()

    {config, aggregate} =
      case deps.load.() do
        {:ok, new_config} -> {new_config, deps.collect.(new_config)}
        _ -> {config, deps.collect.(config)}
      end

    aggregate = inject_throughput(previous_sample, aggregate, now_ms)
    _ = deps.write_html.(config, aggregate)

    refresh_loop(path, config, {now_ms, tokens_total(aggregate)}, deps)
  end

  defp inject_throughput(nil, aggregate, _now_ms), do: aggregate

  defp inject_throughput({prev_ms, prev_tokens}, aggregate, now_ms) do
    elapsed_ms = max(0, now_ms - prev_ms)
    current_tokens = tokens_total(aggregate)

    tps =
      if elapsed_ms == 0 do
        get_in(aggregate, [:totals, :throughput_tps]) || 0
      else
        max(0, current_tokens - prev_tokens) / (elapsed_ms / 1_000)
      end

    put_in(aggregate, [:totals, :throughput_tps], tps)
  end

  defp tokens_total(aggregate), do: get_in(aggregate, [:totals, :tokens_total]) || 0

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      open: fn target -> Dashboard.open(target) end,
      collect: fn config -> Status.collect(config) end,
      write_html: fn config, aggregate -> Dashboard.write_aggregate_html(config, aggregate) end,
      sleep: fn ms -> Process.sleep(ms) end,
      monotonic_ms: fn -> System.monotonic_time(:millisecond) end
    }
  end
end
