defmodule Smithy.Commands.DaemonCmd do
  @moduledoc """
  Handler for `smithy daemon {start|stop|restart} [slug]`.
  If no slug is given, the action is applied to every registered repo.
  """

  alias Smithy.{Config, Supervisor}

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          load_action: (String.t() -> {:ok, String.t()} | {:error, term()}),
          unload_action: (String.t() -> {:ok, String.t()} | {:error, term()}),
          restart_action: (String.t() -> {:ok, String.t()} | {:error, term()})
        }

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([action | rest], _opts, deps) when action in ["start", "stop", "restart"] do
    with {:ok, config} <- deps.load.() do
      slugs =
        case rest do
          [] -> Enum.map(config.repos, & &1.slug)
          [slug] -> [slug]
          _ -> []
        end

      if slugs == [] do
        {:error, :usage}
      else
        results =
          Enum.map(slugs, fn slug ->
            res =
              case action do
                "start" -> deps.load_action.(slug)
                "stop" -> deps.unload_action.(slug)
                "restart" -> deps.restart_action.(slug)
              end

            {slug, res}
          end)

        {:ok, format_results(action, results)}
      end
    end
  end

  def run(_, _, _), do: {:error, :usage}

  defp format_results(action, results) do
    results
    |> Enum.map(fn
      {slug, {:ok, _}} -> "#{action} #{slug}: ok"
      {slug, {:error, reason}} -> "#{action} #{slug}: error #{inspect(reason)}"
    end)
    |> Enum.join("\n")
  end

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      load_action: fn slug -> Supervisor.load(slug) end,
      unload_action: fn slug -> Supervisor.unload(slug) end,
      restart_action: fn slug -> Supervisor.restart(slug) end
    }
  end
end
