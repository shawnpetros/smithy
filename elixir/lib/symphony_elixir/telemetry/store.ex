defmodule SymphonyElixir.Telemetry.Store do
  @moduledoc """
  Append-only JSONL persistence for Telemetry events.

  Layout: `<telemetry_dir>/<repo_slug>/<YYYY-MM-DD>.jsonl`

  Files rotate by UTC date. Reads are line-by-line; writes are single
  append per event with newline. Pure functions only; the writer is
  driven from the `SymphonyElixir.Telemetry` GenServer.
  """

  alias SymphonyElixir.Telemetry.Event

  @default_dir "~/.smithy/telemetry"
  @no_repo "_no_repo"

  @doc """
  Append an event to its date-partitioned file. Creates the parent
  directory if missing.
  """
  @spec write(Event.t(), keyword()) :: :ok | {:error, term()}
  def write(%Event{} = event, opts \\ []) do
    path = file_path_for(event, opts)
    dir = Path.dirname(path)
    line = Event.to_jsonl_line(event)

    case File.mkdir_p(dir) do
      :ok -> File.write(path, [line, "\n"], [:append])
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Return a stream of `Event` structs across all files matching the
  optional `:from`, `:to`, and `:repo_slug` filters.

  Filters:
    * `:from`     - inclusive lower bound `Date.t()`
    * `:to`       - inclusive upper bound `Date.t()`
    * `:repo_slug` - restrict to a single repo subdirectory
    * `:telemetry_dir` - override storage root

  Lines that fail to decode are silently skipped.
  """
  @spec read_stream(keyword()) :: Enumerable.t()
  def read_stream(opts \\ []) do
    opts
    |> list_files()
    |> Stream.flat_map(&stream_file/1)
  end

  @doc """
  List all `.jsonl` files matching the supplied filters. Sorted ascending
  by path (which is ascending by date, since the leaf filename is
  `YYYY-MM-DD.jsonl`).
  """
  @spec list_files(keyword()) :: [Path.t()]
  def list_files(opts \\ []) do
    root = telemetry_dir(opts)

    repo_dirs =
      case opts[:repo_slug] do
        nil -> all_repo_dirs(root)
        slug when is_binary(slug) -> [Path.join(root, slug)]
      end

    from = opts[:from]
    to = opts[:to]

    repo_dirs
    |> Enum.flat_map(&list_repo_files/1)
    |> Enum.filter(&within_range?(&1, from, to))
    |> Enum.sort()
  end

  @doc false
  @spec telemetry_dir(keyword()) :: Path.t()
  def telemetry_dir(opts) do
    dir =
      opts[:telemetry_dir] ||
        Application.get_env(:symphony_elixir, :telemetry_dir) ||
        @default_dir

    Path.expand(dir)
  end

  @doc false
  @spec file_path_for(Event.t(), keyword()) :: Path.t()
  def file_path_for(%Event{} = event, opts) do
    repo = event.repo_slug || @no_repo

    date =
      case event.occurred_at do
        %DateTime{} = dt -> DateTime.to_date(dt)
        _ -> Date.utc_today()
      end

    Path.join([telemetry_dir(opts), repo, Date.to_iso8601(date) <> ".jsonl"])
  end

  defp all_repo_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, _reason} ->
        []
    end
  end

  defp list_repo_files(repo_dir) do
    case File.ls(repo_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(repo_dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp within_range?(path, from, to) do
    case date_from_path(path) do
      {:ok, date} ->
        (is_nil(from) or Date.compare(date, from) != :lt) and
          (is_nil(to) or Date.compare(date, to) != :gt)

      :error ->
        false
    end
  end

  defp date_from_path(path) do
    stem = path |> Path.basename() |> Path.rootname()

    case Date.from_iso8601(stem) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp stream_file(path) do
    Stream.resource(
      fn -> File.open!(path, [:read, :utf8]) end,
      fn io ->
        case IO.read(io, :line) do
          :eof -> {:halt, io}
          {:error, _} -> {:halt, io}
          line -> {[line], io}
        end
      end,
      &File.close/1
    )
    |> Stream.map(&decode_line/1)
    |> Stream.reject(&is_nil/1)
  end

  defp decode_line(line) do
    trimmed = String.trim_trailing(line, "\n")

    if trimmed == "" do
      nil
    else
      case Event.from_jsonl_line(trimmed) do
        {:ok, event} -> event
        _ -> nil
      end
    end
  end
end
