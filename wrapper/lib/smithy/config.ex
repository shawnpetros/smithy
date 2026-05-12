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

  @default_path ".smithy/config.toml"
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
          acknowledged_at: String.t() | nil,
          repos: [repo()],
          extras: map()
        }

  @spec default_path() :: String.t()
  def default_path do
    # Resolve via System.get_env("HOME") so tests that override HOME pick it
    # up at runtime; Path.expand("~/...") consults a snapshot the BEAM captured
    # at startup and ignores later System.put_env calls.
    home = System.get_env("HOME") || System.user_home!() || "/"
    Path.join(home, @default_path)
  end

  @spec defaults() :: t()
  def defaults do
    %{
      default_runtime: @default_runtime,
      default_workflow: @default_workflow,
      symphony_binary: @default_symphony_binary,
      acknowledged_at: nil,
      repos: [],
      extras: %{}
    }
  end

  @doc """
  Returns true when the operator has acknowledged the hold-harmless terms.
  """
  @spec acknowledged?(t()) :: boolean()
  def acknowledged?(%{acknowledged_at: at}) when is_binary(at) and at != "", do: true
  def acknowledged?(_), do: false

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
    {extra_lines, extra_blocks} = extras_sections(Map.get(config, :extras, %{}))

    top_section =
      [
        kv("default_runtime", config.default_runtime),
        kv("default_workflow", config.default_workflow),
        kv("symphony_binary", config.symphony_binary)
      ]
      |> maybe_append_acknowledgement(config)
      |> Kernel.++(extra_lines)
      |> Enum.join("\n")

    repo_blocks =
      "repos"
      |> render_array_of_tables(config.repos)

    [top_section | extra_blocks ++ repo_blocks]
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
      Map.split(rest, [
        "default_runtime",
        "default_workflow",
        "symphony_binary",
        "acknowledged_at"
      ])

    %{
      default_runtime: Map.get(known, "default_runtime", @default_runtime),
      default_workflow: Map.get(known, "default_workflow", @default_workflow),
      symphony_binary: Map.get(known, "symphony_binary", @default_symphony_binary),
      acknowledged_at: Map.get(known, "acknowledged_at"),
      repos: Enum.map(repos, &normalize_repo/1),
      extras: extras
    }
  end

  defp maybe_append_acknowledgement(lines, %{acknowledged_at: at})
       when is_binary(at) and at != "" do
    lines ++ [kv("acknowledged_at", at)]
  end

  defp maybe_append_acknowledgement(lines, _config), do: lines

  defp normalize_repo(%{} = repo) do
    %{
      slug: Map.fetch!(repo, "slug"),
      path: Map.fetch!(repo, "path"),
      workflow: Map.get(repo, "workflow", @default_workflow),
      port: Map.fetch!(repo, "port")
    }
  end

  defp kv(key, value), do: "#{render_key_segment(key)} = #{render_value!(value)}"

  defp extras_sections(map) when map_size(map) == 0, do: {[], []}

  defp extras_sections(map), do: render_entries(map, [])

  defp render_entries(map, path) do
    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.reduce({[], []}, fn {k, v}, {lines, blocks} ->
      key = to_string(k)

      cond do
        scalar_or_scalar_array?(v) ->
          {lines ++ [kv(key, v)], blocks}

        is_map(v) ->
          {lines, blocks ++ render_table(path ++ [key], v)}

        array_of_tables?(v) ->
          {lines, blocks ++ render_array_of_tables(path ++ [key], v)}

        true ->
          raise ArgumentError,
                "unsupported TOML value at #{render_path(path ++ [key])}: #{inspect(v)}"
      end
    end)
  end

  defp render_table(path, map) do
    {lines, blocks} = render_entries(map, path)
    [Enum.join(["[#{render_path(path)}]" | lines], "\n") | blocks]
  end

  defp render_array_of_tables(path, rows) do
    rows
    |> Enum.flat_map(fn row ->
      {lines, blocks} = render_entries(row, List.wrap(path))
      [Enum.join(["[[#{render_path(path)}]]" | lines], "\n") | blocks]
    end)
  end

  defp scalar_or_scalar_array?(value), do: scalar?(value) or scalar_array?(value)

  defp scalar?(value) when is_binary(value), do: true
  defp scalar?(value) when is_integer(value), do: true
  defp scalar?(value) when is_float(value), do: true
  defp scalar?(value) when is_boolean(value), do: true
  defp scalar?(_value), do: false

  defp scalar_array?(value) when is_list(value), do: Enum.all?(value, &scalar?/1)
  defp scalar_array?(_value), do: false

  defp array_of_tables?([first | _] = value), do: is_map(first) and Enum.all?(value, &is_map/1)
  defp array_of_tables?(_value), do: false

  defp render_value!(value) when is_binary(value), do: Jason.encode!(value)
  defp render_value!(value) when is_integer(value), do: Integer.to_string(value)
  defp render_value!(value) when is_float(value), do: Float.to_string(value)
  defp render_value!(value) when is_boolean(value), do: to_string(value)

  defp render_value!(value) when is_list(value) do
    if scalar_array?(value) do
      "[" <> Enum.map_join(value, ", ", &render_value!/1) <> "]"
    else
      raise ArgumentError, "unsupported TOML array value: #{inspect(value)}"
    end
  end

  defp render_value!(value), do: raise(ArgumentError, "unsupported TOML value: #{inspect(value)}")

  defp render_path(path), do: path |> List.wrap() |> Enum.map_join(".", &render_key_segment/1)

  defp render_key_segment(key) do
    key = to_string(key)

    if String.match?(key, ~r/^[A-Za-z0-9_-]+$/) do
      key
    else
      Jason.encode!(key)
    end
  end

  defp resolve_path(nil), do: default_path()
  defp resolve_path(path), do: Path.expand(path)
end
