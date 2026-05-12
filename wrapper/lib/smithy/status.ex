defmodule Smithy.Status do
  @moduledoc """
  Queries each registered Symphony's `GET /api/v1/state` and assembles
  an aggregate status struct for the TUI / JSON output.

  See `SymphonyElixirWeb.Presenter.state_payload/2` for the per-repo
  response shape:

      {
        "generated_at": "...",
        "counts": {"running": N, "retrying": M},
        "running": [
          {
            "issue_identifier": "MT-725",
            "state": "Todo",
            "session_id": "...",
            "started_at": "...",
            "last_event": "...",
            "last_message": "...",
            "tokens": {"input_tokens": ..., "output_tokens": ..., "total_tokens": ...}
          }
        ],
        "retrying": [...],
        "codex_totals": {...},
        "rate_limits": {...}
      }
  """

  alias Smithy.Config

  @type repo_status :: %{
          slug: String.t(),
          port: pos_integer(),
          url: String.t(),
          status: :online | :offline,
          error: term() | nil,
          payload: map() | nil
        }

  @type aggregate :: %{
          repos: [repo_status()],
          totals: %{
            registered: non_neg_integer(),
            active: non_neg_integer(),
            agents_running: non_neg_integer(),
            agents_capacity: non_neg_integer() | nil,
            throughput_tps: number(),
            tokens_in: non_neg_integer(),
            tokens_out: non_neg_integer(),
            tokens_total: non_neg_integer()
          },
          generated_at: String.t()
        }

  @type http_client :: (String.t() -> {:ok, map()} | {:error, term()})

  @doc """
  Collects status from every repo in `config`. Off-line repos are tagged
  `:offline` rather than crashing the aggregate.
  """
  @spec collect(Config.t(), http_client()) :: aggregate()
  def collect(config, http_client \\ &default_http_client/1) do
    statuses =
      config.repos
      |> Enum.map(&query_one(&1, http_client))

    %{
      repos: statuses,
      totals: totals(statuses, config.repos),
      generated_at: iso_now()
    }
  end

  @doc """
  Queries a single repo's state endpoint and normalizes the response.
  """
  @spec query_one(Config.repo(), http_client()) :: repo_status()
  def query_one(repo, http_client \\ &default_http_client/1) do
    url = "http://localhost:#{repo.port}/api/v1/state"

    case http_client.(url) do
      {:ok, payload} when is_map(payload) ->
        %{
          slug: repo.slug,
          port: repo.port,
          url: url,
          status: :online,
          error: nil,
          payload: payload
        }

      {:error, reason} ->
        %{
          slug: repo.slug,
          port: repo.port,
          url: url,
          status: :offline,
          error: reason,
          payload: nil
        }
    end
  end

  defp totals(statuses, repos) do
    online = Enum.filter(statuses, &(&1.status == :online))

    {tokens_in, tokens_out, tokens_total, agents, capacity, capacity_seen?, throughput_tps} =
      online
      |> Enum.reduce({0, 0, 0, 0, 0, false, 0}, fn s, {ti, to, tt, ag, cap, cap_seen?, tps} ->
        running = get_in(s.payload, ["counts", "running"]) |> integer_or_zero()
        repo_capacity = agent_capacity(s.payload)

        {tin, tout, ttot} = token_totals(s.payload)

        {
          ti + tin,
          to + tout,
          tt + ttot,
          ag + running,
          cap + (repo_capacity || 0),
          cap_seen? or not is_nil(repo_capacity),
          tps + throughput_tps(s.payload)
        }
      end)

    %{
      registered: length(repos),
      active: length(online),
      agents_running: agents,
      agents_capacity: if(capacity_seen?, do: capacity, else: nil),
      throughput_tps: throughput_tps,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      tokens_total: tokens_total
    }
  end

  defp token_totals(payload) when is_map(payload) do
    case payload["codex_totals"] do
      %{} = totals ->
        {
          totals["input_tokens"] || 0,
          totals["output_tokens"] || 0,
          totals["total_tokens"] || 0
        }

      _ ->
        (payload["running"] || [])
        |> Enum.reduce({0, 0, 0}, fn entry, {a, b, c} ->
          t = entry["tokens"] || %{}

          {
            a + (t["input_tokens"] || 0),
            b + (t["output_tokens"] || 0),
            c + (t["total_tokens"] || 0)
          }
        end)
    end
  end

  defp agent_capacity(payload) when is_map(payload) do
    counts = payload["counts"] || %{}

    capacity =
      counts["max_agents"] ||
        counts["max"] ||
        counts["capacity"] ||
        payload["max_agents"] ||
        payload["agent_capacity"]

    integer_or_nil(capacity)
  end

  defp agent_capacity(_payload), do: nil

  defp throughput_tps(payload) when is_map(payload) do
    (payload["throughput_tps"] || get_in(payload, ["throughput", "tps"]))
    |> number_or_zero()
  end

  defp throughput_tps(_payload), do: 0

  defp integer_or_zero(value), do: integer_or_nil(value) || 0

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp number_or_zero(value) when is_number(value), do: value

  defp number_or_zero(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp number_or_zero(_value), do: 0

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc """
  Default HTTP client built on `:httpc`. 2-second timeout per request.
  """
  @spec default_http_client(String.t()) :: {:ok, map()} | {:error, term()}
  def default_http_client(url) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), [{~c"accept", ~c"application/json"}]}

    http_opts = [timeout: 2_000, connect_timeout: 1_000]
    opts = [body_format: :binary]

    case :httpc.request(:get, request, http_opts, opts) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, json}
          err -> err
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
