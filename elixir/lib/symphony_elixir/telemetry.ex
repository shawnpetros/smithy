defmodule SymphonyElixir.Telemetry do
  @moduledoc """
  Structured runtime telemetry for Smithy. Records events at every agent
  invocation boundary so wall-clock, token, and cost data is available for
  future estimation work and the planned `smithy stats` command.

  ## Usage

      Telemetry.emit(:turn_start, ticket: "PER-150", mode: :builder, runtime: :codex)
      # ... agent does work ...
      Telemetry.emit(:turn_end, ticket: "PER-150", duration_ms: 4127, outcome: :success,
                                input_tokens: 6, output_tokens: 25, cost_usd: 0.195)

  ## Storage

  Events append to `<telemetry_dir>/<repo_slug>/<YYYY-MM-DD>.jsonl`. Default
  `telemetry_dir` is `~/.smithy/telemetry`. Override per-call via opts or
  globally via `config :symphony_elixir, :telemetry_dir, "/path"`.

  ## Async + non-blocking

  Writes happen in a separate GenServer process. `emit/2` casts the event
  onto the process mailbox; it never blocks on disk I/O. When the
  Telemetry process is down or unregistered, `emit/2` becomes a no-op and
  logs a one-line warning.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Telemetry.{Event, Store}

  @queue_warn_threshold 1_000

  # --- Public API ---------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record an event. Non-blocking; returns `:ok` always.

  Unknown keys (anything not in the Event struct) are folded into
  `:metadata` so runtime-specific extras flow through without ceremony.
  """
  @spec emit(Event.event_kind(), keyword()) :: :ok
  def emit(kind, opts \\ []) do
    event = Event.build(kind, opts)

    case Process.whereis(__MODULE__) do
      nil ->
        Logger.warning(
          "Telemetry GenServer not running; dropping event #{inspect(kind)} ticket=#{inspect(event.ticket)}"
        )

        :ok

      pid when is_pid(pid) ->
        GenServer.cast(pid, {:write, event})
    end
  end

  @doc """
  Stream events from disk matching the supplied filters.

  Filters:
    * `:from`         - inclusive lower bound `Date.t()`
    * `:to`           - inclusive upper bound `Date.t()`
    * `:repo_slug`    - restrict to one repo
    * `:telemetry_dir` - override storage root
  """
  @spec query(keyword()) :: Enumerable.t()
  def query(opts \\ []) do
    Store.read_stream(opts)
  end

  @doc """
  Aggregate stats across a date range. Returns the summary map
  documented in the module spec. Empty result sets return zeros, not
  crashes.
  """
  @spec stats(keyword()) :: map()
  def stats(opts \\ []) do
    events = opts |> query() |> Enum.to_list()

    from_dt = date_to_datetime(opts[:from], :start)
    to_dt = date_to_datetime(opts[:to], :end)

    turn_ends = Enum.filter(events, &(&1.event == :turn_end))

    durations =
      turn_ends
      |> Enum.map(& &1.duration_ms)
      |> Enum.reject(&is_nil/1)

    costs =
      turn_ends
      |> Enum.map(& &1.cost_usd)
      |> Enum.reject(&is_nil/1)

    %{
      range: %{from: from_dt, to: to_dt},
      tickets_total: count_unique_tickets(events),
      tickets_by_outcome: tickets_by_outcome(turn_ends),
      wall_clock_ms: wall_clock_summary(durations),
      tokens: token_totals(turn_ends),
      cost_usd: cost_summary(costs),
      runtime_split: split_by(turn_ends, & &1.runtime),
      mode_split: split_by(turn_ends, & &1.mode)
    }
  end

  # --- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      telemetry_dir: opts[:telemetry_dir],
      written: 0,
      dropped: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:write, %Event{} = event}, state) do
    maybe_warn_backlog()

    new_state =
      case Store.write(event, telemetry_dir: state.telemetry_dir) do
        :ok ->
          %{state | written: state.written + 1}

        {:error, reason} ->
          Logger.error(
            "Telemetry write failed event=#{inspect(event.event)} reason=#{inspect(reason)}"
          )

          %{state | dropped: state.dropped + 1}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  # --- Internals ----------------------------------------------------------

  defp maybe_warn_backlog do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    if len >= @queue_warn_threshold do
      Logger.warning("Telemetry mailbox backlog len=#{len}; events still queued, not dropped")
    end
  end

  defp count_unique_tickets(events) do
    events
    |> Enum.map(& &1.ticket)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp tickets_by_outcome(turn_ends) do
    base = %{success: 0, timeout: 0, error: 0, budget_exceeded: 0, in_flight: 0}

    turn_ends
    |> Enum.reduce(base, fn ev, acc ->
      key = ev.outcome || :in_flight
      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  defp wall_clock_summary([]) do
    %{median: 0, p95: 0, max: 0, samples: 0}
  end

  defp wall_clock_summary(durations) do
    sorted = Enum.sort(durations)
    n = length(sorted)

    %{
      median: percentile(sorted, n, 0.5),
      p95: percentile(sorted, n, 0.95),
      max: List.last(sorted),
      samples: n
    }
  end

  defp percentile(sorted, n, p) when n > 0 do
    idx = min(round(n * p), n - 1)
    Enum.at(sorted, idx)
  end

  defp token_totals(turn_ends) do
    input = sum_field(turn_ends, :input_tokens)
    output = sum_field(turn_ends, :output_tokens)

    %{input: input, output: output, total: input + output}
  end

  defp sum_field(events, field) do
    Enum.reduce(events, 0, fn ev, acc ->
      case Map.get(ev, field) do
        nil -> acc
        n when is_integer(n) -> acc + n
        _ -> acc
      end
    end)
  end

  defp cost_summary([]) do
    %{total: 0.0, median_per_ticket: 0.0, max_per_ticket: 0.0}
  end

  defp cost_summary(costs) do
    sorted = Enum.sort(costs)
    n = length(sorted)
    total = Enum.sum(costs)

    %{
      total: round_money(total),
      median_per_ticket: round_money(percentile(sorted, n, 0.5)),
      max_per_ticket: round_money(List.last(sorted))
    }
  end

  defp round_money(value) when is_float(value), do: Float.round(value, 2)
  defp round_money(value), do: value

  defp split_by(events, fun) do
    Enum.reduce(events, %{}, fn ev, acc ->
      case fun.(ev) do
        nil -> acc
        key -> Map.update(acc, key, 1, &(&1 + 1))
      end
    end)
  end

  defp date_to_datetime(nil, _bound), do: nil

  defp date_to_datetime(%Date{} = d, :start) do
    {:ok, dt} = DateTime.new(d, ~T[00:00:00], "Etc/UTC")
    dt
  end

  defp date_to_datetime(%Date{} = d, :end) do
    {:ok, dt} = DateTime.new(d, ~T[23:59:59], "Etc/UTC")
    dt
  end

  defp date_to_datetime(%DateTime{} = dt, _bound), do: dt
end
