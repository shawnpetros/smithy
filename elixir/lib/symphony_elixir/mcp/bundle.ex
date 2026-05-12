defmodule SymphonyElixir.MCP.Bundle do
  @moduledoc """
  Named MCP server config bundles.

  A "bundle" is a map of `server_name -> server_config` shaped like the
  inner object of claude-code's `--mcp-config` JSON. One bundle file MAY
  declare multiple servers; the bundle's name describes purpose (e.g.
  `linear-read`, `github`, `playwright`), not server count.

  Bundles are JSON files. The default library ships under
  `priv/mcp_bundles/<name>.json`. Per-repo overrides may live at
  `<repo>/.smithy/mcp_bundles/<name>.json` and are passed in via the
  `:repo_paths` option to `load/2` and `list_available/1`. When a name
  exists in both an override path and `priv/`, the override wins. Among
  multiple `repo_paths`, earlier entries win.

  Symphony's runtime layer composes one or more bundles into a single
  `--mcp-config` file at spawn time using `merge/1` and `write_config/2`.

  This module is intentionally minimal: only `load/2` and `write_config/2`
  perform IO; `merge/1` and `list_available/1` are pure (modulo directory
  reads in the latter). No dependency on the rest of the harness.
  """

  @type bundle :: %{required(String.t()) => map()}

  @bundles_subdir "mcp_bundles"

  @doc """
  Load a bundle by name.

  Search order:

    1. Each path in `opts[:repo_paths]`, in order. Each entry is a
       directory that may contain `<name>.json`.
    2. The bundled library at `priv/mcp_bundles/<name>.json`.

  Returns `{:ok, bundle}` on success, `{:error, :not_found}` when no
  matching file exists in any search location, or `{:error, {:invalid_json,
  reason}}` when a candidate file fails to parse.
  """
  @spec load(String.t(), keyword()) :: {:ok, bundle()} | {:error, term()}
  def load(name, opts \\ []) when is_binary(name) do
    case resolve_path(name, opts) do
      {:ok, path} -> read_bundle(path)
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Merge multiple bundles into one. Later bundles override earlier on key
  collisions. Pure function; safe to call with `[]` (returns `%{}`).
  """
  @spec merge([bundle()]) :: bundle()
  def merge(bundles) when is_list(bundles) do
    Enum.reduce(bundles, %{}, fn bundle, acc ->
      Map.merge(acc, bundle)
    end)
  end

  @doc """
  Write a bundle to `dest_path` as a JSON file shaped for claude-code's
  `--mcp-config` flag. The on-disk schema wraps the bundle in an
  `"mcpServers"` envelope, matching the format claude-code expects.

  Creates intermediate directories as needed. Returns `{:ok, dest_path}`
  on success.
  """
  @spec write_config(bundle(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_config(bundle, dest_path) when is_map(bundle) and is_binary(dest_path) do
    payload = %{"mcpServers" => bundle}

    with {:ok, json} <- Jason.encode(payload, pretty: true),
         :ok <- File.mkdir_p(Path.dirname(dest_path)),
         :ok <- File.write(dest_path, json) do
      {:ok, dest_path}
    end
  end

  @doc """
  List bundle names available across the search paths. Combines all
  `opts[:repo_paths]` with the bundled library. Returns a sorted, unique
  list of bundle names (without the `.json` extension).
  """
  @spec list_available(keyword()) :: [String.t()]
  def list_available(opts \\ []) do
    search_dirs(opts)
    |> Enum.flat_map(&list_dir/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- internals -----------------------------------------------------------

  @spec resolve_path(String.t(), keyword()) :: {:ok, Path.t()} | :error
  defp resolve_path(name, opts) do
    filename = name <> ".json"

    opts
    |> search_dirs()
    |> Enum.map(&Path.join(&1, filename))
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @spec search_dirs(keyword()) :: [Path.t()]
  defp search_dirs(opts) do
    repo_dirs = Keyword.get(opts, :repo_paths, [])
    repo_dirs ++ [priv_dir()]
  end

  @spec priv_dir() :: Path.t()
  defp priv_dir do
    case :code.priv_dir(:symphony_elixir) do
      {:error, :bad_name} ->
        # Fallback for tests / non-OTP-loaded contexts: resolve relative to
        # this source file (lib/symphony_elixir/mcp/bundle.ex -> ../../../priv).
        Path.join([File.cwd!(), "priv", @bundles_subdir])

      priv when is_list(priv) ->
        Path.join(List.to_string(priv), @bundles_subdir)
    end
  end

  @spec list_dir(Path.t()) :: [String.t()]
  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.basename(&1, ".json"))

      {:error, _} ->
        []
    end
  end

  @spec read_bundle(Path.t()) :: {:ok, bundle()} | {:error, term()}
  defp read_bundle(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      case decoded do
        %{} = map -> {:ok, strip_comments(map)}
        _ -> {:error, {:invalid_json, :not_an_object}}
      end
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Bundle files may include top-level `_comment` keys for human notes.
  # Strip them so consumers see only server definitions.
  @spec strip_comments(map()) :: map()
  defp strip_comments(map) do
    map
    |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "_") end)
    |> Map.new()
  end
end
