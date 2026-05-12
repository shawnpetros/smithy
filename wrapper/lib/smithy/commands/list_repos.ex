defmodule Smithy.Commands.ListRepos do
  @moduledoc """
  Handler for `smithy list-repos`.
  """

  alias Smithy.{Config, RepoRegistry}

  @type deps :: %{load: (-> {:ok, Config.t()} | {:error, term()})}

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(_positional \\ [], _opts \\ %{}, deps \\ default_deps()) do
    with {:ok, config} <- deps.load.() do
      case RepoRegistry.list(config) do
        [] ->
          {:ok, "no repos registered\n(use `smithy add-repo <slug> <path>` to register)"}

        repos ->
          rows =
            Enum.map(repos, fn r ->
              "  #{pad(r.slug, 18)}  port #{r.port}  #{r.path}  (#{r.workflow})"
            end)

          {:ok, "registered repos:\n" <> Enum.join(rows, "\n")}
      end
    end
  end

  defp pad(s, width) do
    s = to_string(s)
    s <> String.duplicate(" ", max(0, width - String.length(s)))
  end

  defp default_deps, do: %{load: fn -> Config.load() end}
end
