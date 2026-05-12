defmodule Smithy.Config do
  @moduledoc """
  Reads and writes `~/.smithy/config.toml`.

  Schema (per `v2/SPEC.md` § "Smithy wrapper"):

      default_runtime = "codex"
      default_workflow = "WORKFLOW.md"
      symphony_binary = "/usr/local/bin/symphony"  # optional override

      [[repos]]
      slug = "smithy"
      path = "/Users/shawnpetros/projects/smithy"
      workflow = "WORKFLOW.md"
      port = 4001

  The legacy daemon config in the same file (linear_teams, repo_paths, etc.)
  is preserved verbatim by `write/2`. v1 only manages the wrapper-specific keys
  and the `[[repos]]` array.
  """

  @default_path "~/.smithy/config.toml"
  @default_runtime "codex"
  @default_workflow "WORKFLOW.md"
  @default_symphony_binary "/usr/local/bin/symphony"

  @type repo :: %{
          slug: String.t(),
          path: String.t(),
          workflow: String.t(),
          port: pos_integer()
        }

  @type t :: %{
          default_runtime: String.t(),
          default_workflow: String.t(),
          symphony_binary: String.t(),
          repos: [repo()],
          extras: map()
        }

  @spec default_path() :: String.t()
  def default_path, do: @default_path |> Path.expand()

  @spec defaults() :: t()
  def defaults do
    %{
      default_runtime: @default_runtime,
      default_workflow: @default_workflow,
      symphony_binary: @default_symphony_binary,
      repos: [],
      extras: %{}
    }
  end

  @doc """
  Loads the config from disk. Missing file returns defaults.
  Parse errors return `{:error, reason}`.
  """
  @spec load(String.t() | nil) :: {:ok, t()} | {:error, term()}
  def load(path \\ nil) do
    path = resolve_path(path)

    case File.read(path) do
      {:ok, body} -> parse(body)
      {:error, :enoent} -> {:ok, defaults()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `load/1`, but raises on error.
  """
  @spec load!(String.t() | nil) :: t()
  def load!(path \\ nil) do
    case load(path) do
      {:ok, config} -> config
      {:error, reason} -> raise "failed to load smithy config: #{inspect(reason)}"
    end
  end

  @doc """
  Parses TOML text into a config map. Tolerant of missing top-level keys.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(body) when is_binary(body) do
    case Toml.decode(body) do
      {:ok, raw} ->
        {:ok, build(raw)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Writes the config back to disk. Preserves `extras` (unknown top-level keys
  from the prior config). Returns `:ok` or `{:error, reason}`.
  """
  @spec write(t(), String.t() | nil) :: :ok | {:error, term()}
  def write(config, path \\ nil) do
    path = resolve_path(path)

    case File.mkdir_p(Path.dirname(path)) do
      :ok -> File.write(path, render(config))
      err -> err
    end
  end

  @doc """
  Renders a config map to TOML text.
  """
  @spec render(t()) :: String.t()
  def render(config) do
    top_lines =
      [
        kv("default_runtime", config.default_runtime),
        kv("default_workflow", config.default_workflow),
        kv("symphony_binary", config.symphony_binary)
      ] ++ extras_lines(Map.get(config, :extras, %{}))

    repo_blocks =
      config.repos
      |> Enum.map(&render_repo/1)

    [Enum.join(top_lines, "\n"), Enum.join(repo_blocks, "\n")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp build(raw) when is_map(raw) do
    {repos, rest} = Map.pop(raw, "repos", [])

    {
      known,
      extras
    } =
      Map.split(rest, ["default_runtime", "default_workflow", "symphony_binary"])

    %{
      default_runtime: Map.get(known, "default_runtime", @default_runtime),
      default_workflow: Map.get(known, "default_workflow", @default_workflow),
      symphony_binary: Map.get(known, "symphony_binary", @default_symphony_binary),
      repos: Enum.map(repos, &normalize_repo/1),
      extras: extras
    }
  end

  defp normalize_repo(%{} = repo) do
    %{
      slug: Map.fetch!(repo, "slug"),
      path: Map.fetch!(repo, "path"),
      workflow: Map.get(repo, "workflow", @default_workflow),
      port: Map.fetch!(repo, "port")
    }
  end

  defp render_repo(repo) do
    """
    [[repos]]
    slug = "#{repo.slug}"
    path = "#{repo.path}"
    workflow = "#{repo.workflow}"
    port = #{repo.port}
    """
    |> String.trim_trailing()
  end

  defp kv(key, value) when is_binary(value), do: ~s(#{key} = "#{value}")
  defp kv(key, value) when is_integer(value), do: "#{key} = #{value}"
  defp kv(key, value) when is_boolean(value), do: "#{key} = #{value}"

  defp extras_lines(map) when map_size(map) == 0, do: []

  defp extras_lines(map) do
    map
    |> Enum.sort()
    |> Enum.map(fn {k, v} -> render_extra(k, v) end)
    |> Enum.reject(&is_nil/1)
  end

  defp render_extra(k, v) when is_binary(v), do: kv(k, v)
  defp render_extra(k, v) when is_integer(v), do: kv(k, v)
  defp render_extra(k, v) when is_boolean(v), do: kv(k, v)

  defp render_extra(k, v) when is_list(v) do
    if Enum.all?(v, &is_binary/1) do
      "#{k} = [#{Enum.map_join(v, ", ", &~s("#{&1}"))}]"
    else
      # Skip arrays we can't trivially round-trip; better to drop than corrupt.
      nil
    end
  end

  defp render_extra(_k, _v), do: nil

  defp resolve_path(nil), do: default_path()
  defp resolve_path(path), do: Path.expand(path)
end
