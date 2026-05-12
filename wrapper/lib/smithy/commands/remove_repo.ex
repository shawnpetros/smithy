defmodule Smithy.Commands.RemoveRepo do
  @moduledoc """
  Handler for `smithy remove-repo <slug>`.
  Unloads the launchd plist (best-effort) and removes the plist file.
  """

  alias Smithy.{Config, RepoRegistry, Supervisor}

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          write: (Config.t() -> :ok | {:error, term()}),
          unload: (String.t() -> {:ok, String.t()} | {:error, term()}),
          uninstall: (String.t() -> :ok | {:error, term()})
        }

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([slug], _opts, deps) do
    with {:ok, config} <- deps.load.(),
         {:ok, {next_config, removed}} <- RepoRegistry.remove(config, slug),
         :ok <- deps.write.(next_config),
         _ = deps.unload.(slug),
         :ok <- deps.uninstall.(slug) do
      {:ok, "removed #{removed.slug}"}
    end
  end

  def run(_, _, _), do: {:error, :usage}

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      write: fn config -> Config.write(config) end,
      unload: fn slug -> Supervisor.unload(slug) end,
      uninstall: fn slug -> Supervisor.uninstall(slug) end
    }
  end
end
