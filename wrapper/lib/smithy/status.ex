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
        %{slug: repo.slug, port: repo.port, url: url, status: :online, error: nil, payload: payload}

      {:error, reason} ->
        %{slug: repo.slug, port: repo.port, url: url, status: :offline, error: reason, payload: nil}
    end
  end

  defp totals(statuses, repos) do
    online = Enum.filter(statuses, &(&1.status == :online))

    {tokens_in, tokens_out, tokens_total, agents} =
      online
      |> Enum.reduce({0, 0, 0, 0}, fn s, {ti, to, tt, ag} ->
        running = get_in(s.payload, ["counts", "running"]) || 0

        {tin, tout, ttot} =
          (s.payload["running"] || [])
          |> Enum.reduce({0, 0, 0}, fn entry, {a, b, c} ->
            t = entry["tokens"] || %{}
            {a + (t["input_tokens"] || 0), b + (t["output_tokens"] || 0),
             c + (t["total_tokens"] || 0)}
          end)

        {ti + tin, to + tout, tt + ttot, ag + running}
      end)

    %{
      registered: length(repos),
      active: length(online),
      agents_running: agents,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      tokens_total: tokens_total
    }
  end

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
