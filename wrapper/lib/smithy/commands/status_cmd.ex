defmodule Smithy.Commands.StatusCmd do
  @moduledoc """
  Handler for `smithy status`, `smithy bellows`, `smithy forge`.

  Options:
    --json   emit JSON instead of TUI
    --web    open the aggregate browser dashboard instead of printing
  """

  alias Smithy.{Config, Dashboard, Status, TUI}

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          collect: (Config.t() -> Status.aggregate()),
          write_dashboard: (Config.t() -> {:ok, String.t()} | {:error, term()}),
          open: (String.t() -> {:ok, String.t()} | {:error, term()})
        }

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([], opts, deps) do
    with {:ok, config} <- deps.load.() do
      cond do
        Map.get(opts, :web) ->
          with {:ok, path} <- deps.write_dashboard.(config),
               {:ok, _} <- deps.open.("file://" <> path) do
            {:ok, "opened #{path}"}
          end

        Map.get(opts, :json) ->
          aggregate = deps.collect.(config)
          {:ok, Jason.encode!(aggregate, pretty: true)}

        true ->
          aggregate = deps.collect.(config)
          {:ok, TUI.render(aggregate, color: color?())}
      end
    end
  end

  def run(_, _, _), do: {:error, :usage}

  defp color?, do: System.get_env("NO_COLOR") in [nil, ""] and IO.ANSI.enabled?()

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      collect: fn config -> Status.collect(config) end,
      write_dashboard: fn config -> Dashboard.write_aggregate_html(config) end,
      open: fn target -> Dashboard.open(target) end
    }
  end
end
