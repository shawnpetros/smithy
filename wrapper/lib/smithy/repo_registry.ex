defmodule Smithy.RepoRegistry do
  @moduledoc """
  CRUD on the registered repos inside a `Smithy.Config` map.

  Pure data operations: this module never touches disk on its own. Callers
  load via `Smithy.Config.load/1`, mutate via the functions here, then write
  back via `Smithy.Config.write/2`.
  """

  alias Smithy.Config

  @first_port 4001

  @type opts :: [
          workflow: String.t() | nil,
          port: pos_integer() | nil
        ]

  @doc """
  Returns the list of registered repos.
  """
  @spec list(Config.t()) :: [Config.repo()]
  def list(%{repos: repos}), do: repos

  @doc """
  Finds a repo by slug. Returns `{:ok, repo}` or `{:error, :not_found}`.
  """
  @spec fetch(Config.t(), String.t()) :: {:ok, Config.repo()} | {:error, :not_found}
  def fetch(%{repos: repos}, slug) do
    case Enum.find(repos, &(&1.slug == slug)) do
      nil -> {:error, :not_found}
      repo -> {:ok, repo}
    end
  end

  @doc """
  Adds a new repo. Rejects duplicate slugs and duplicate ports. If `:port`
  is not provided, the next free port starting at #{@first_port} is assigned.

  Returns `{:ok, {new_config, added_repo}}` or `{:error, reason}`.
  """
  @spec add(Config.t(), String.t(), String.t(), opts()) ::
          {:ok, {Config.t(), Config.repo()}} | {:error, term()}
  def add(%{repos: repos} = config, slug, path, opts \\ []) do
    cond do
      slug in (repos |> Enum.map(& &1.slug)) ->
        {:error, {:duplicate_slug, slug}}

      not is_binary(slug) or slug == "" ->
        {:error, :invalid_slug}

      not is_binary(path) or path == "" ->
        {:error, :invalid_path}

      true ->
        workflow = Keyword.get(opts, :workflow) || config.default_workflow
        port = Keyword.get(opts, :port) || next_port(repos)

        case validate_port(repos, port) do
          :ok ->
            repo = %{
              slug: slug,
              path: Path.expand(path),
              workflow: workflow,
              port: port
            }

            {:ok, {%{config | repos: repos ++ [repo]}, repo}}

          err ->
            err
        end
    end
  end

  @doc """
  Removes a repo by slug. Returns `{:ok, {new_config, removed_repo}}`
  or `{:error, :not_found}`.
  """
  @spec remove(Config.t(), String.t()) :: {:ok, {Config.t(), Config.repo()}} | {:error, :not_found}
  def remove(%{repos: repos} = config, slug) do
    case Enum.split_with(repos, &(&1.slug == slug)) do
      {[], _} -> {:error, :not_found}
      {[removed], rest} -> {:ok, {%{config | repos: rest}, removed}}
    end
  end

  @doc """
  Returns the next free port, starting at #{@first_port}.
  """
  @spec next_port([Config.repo()]) :: pos_integer()
  def next_port(repos) do
    used = repos |> Enum.map(& &1.port) |> MapSet.new()

    Stream.iterate(@first_port, &(&1 + 1))
    |> Enum.find(&(!MapSet.member?(used, &1)))
  end

  defp validate_port(repos, port) when is_integer(port) and port > 0 and port < 65_536 do
    if Enum.any?(repos, &(&1.port == port)) do
      {:error, {:duplicate_port, port}}
    else
      :ok
    end
  end

  defp validate_port(_repos, port), do: {:error, {:invalid_port, port}}
end
