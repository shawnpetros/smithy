defmodule Smithy.Commands.AddRepo do
  @moduledoc """
  Handler for `smithy add-repo <slug> <path> [--workflow PATH] [--port PORT]`.
  """

  alias Smithy.{Config, RepoRegistry, Supervisor}

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          write: (Config.t() -> :ok | {:error, term()}),
          install: (Config.repo(), Config.t() -> {:ok, String.t()} | {:error, term()})
        }

  @doc """
  Args: positional [slug, path], opts %{workflow: ..., port: ...}.
  """
  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([slug, path], opts, deps) do
    with {:ok, config} <- deps.load.(),
         {:ok, {next_config, repo}} <-
           RepoRegistry.add(config, slug, path,
             workflow: Map.get(opts, :workflow),
             port: Map.get(opts, :port)
           ),
         :ok <- deps.write.(next_config),
         {:ok, plist_path} <- deps.install.(repo, next_config) do
      {:ok,
       "registered #{repo.slug} at #{repo.path} (port #{repo.port})\n" <>
         "plist: #{plist_path}\n" <>
         "load with: smithy daemon start #{repo.slug}"}
    end
  end

  def run(_, _, _), do: {:error, :usage}

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      write: fn config -> Config.write(config) end,
      install: fn repo, config -> Supervisor.install(repo, config) end
    }
  end
end
