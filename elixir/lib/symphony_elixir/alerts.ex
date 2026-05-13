defmodule SymphonyElixir.Alerts do
  @moduledoc false

  use GenServer
  require Logger

  alias SymphonyElixir.Alerts.Telegram
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  defstruct debounce: %{}, exhausted_runtimes: MapSet.new()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec rate_limits_updated(map()) :: :ok
  def rate_limits_updated(rate_limits) when is_map(rate_limits) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:rate_limits_updated, rate_limits})
    end

    :ok
  end

  def rate_limits_updated(_), do: :ok

  @spec retry_attempt(String.t(), String.t() | nil, integer(), String.t() | nil) :: :ok
  def retry_attempt(issue_id, identifier, attempt, error)
      when is_binary(issue_id) and is_integer(attempt) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:retry_attempt, issue_id, identifier, attempt, error})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :daemon_started, 500)
    monitor_orchestrator()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_cast({:rate_limits_updated, rate_limits}, state) do
    {:noreply, handle_rate_limits(state, rate_limits)}
  end

  def handle_cast({:retry_attempt, issue_id, identifier, attempt, error}, state) do
    {:noreply, handle_retry_alert(state, issue_id, identifier, attempt, error)}
  end

  @impl true
  def handle_info(:daemon_started, state) do
    settings = alerts_settings()

    state =
      if settings.enabled do
        text = "🟢 Smithy daemon started (PID #{:os.getpid()})"
        {_, new_state} = notify_with_debounce(state, "daemon:started", text, settings)
        new_state
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :shutdown}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, {:shutdown, _}}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    settings = alerts_settings()

    state =
      if settings.enabled do
        text = "🟣 Smithy orchestrator crashed: #{inspect(reason)}"
        {_, new_state} = notify_with_debounce(state, "daemon:crash", text, settings)
        new_state
      else
        state
      end

    Process.send_after(self(), :remonitor_orchestrator, 2_000)
    {:noreply, state}
  end

  def handle_info(:remonitor_orchestrator, state) do
    monitor_orchestrator()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_rate_limits(state, rate_limits) do
    settings = alerts_settings()
    if settings.enabled, do: do_handle_rate_limits(state, rate_limits, settings), else: state
  end

  defp do_handle_rate_limits(state, rate_limits, settings) do
    limit_id = map_get_any(rate_limits, ["limit_id", :limit_id, "limit_name", :limit_name]) || "unknown"
    primary = map_get_any(rate_limits, ["primary", :primary])
    credits = map_get_any(rate_limits, ["credits", :credits])

    is_exhausted = bucket_exhausted?(primary, credits)
    was_exhausted = MapSet.member?(state.exhausted_runtimes, limit_id)

    state =
      cond do
        is_exhausted and not was_exhausted ->
          {_, new_state} =
            notify_with_debounce(
              state,
              "rate_limit:#{limit_id}:exhausted",
              "🔴 Smithy critical: #{limit_id} exhausted, dispatch paused",
              settings
            )

          %{new_state | exhausted_runtimes: MapSet.put(new_state.exhausted_runtimes, limit_id)}

        not is_exhausted and was_exhausted ->
          {_, new_state} =
            notify_with_debounce(
              state,
              "rate_limit:#{limit_id}:recovered",
              "🟢 Smithy recovered: #{limit_id} window reset, dispatch resumed",
              settings
            )

          %{new_state | exhausted_runtimes: MapSet.delete(new_state.exhausted_runtimes, limit_id)}

        true ->
          state
      end

    check_threshold_alerts(state, primary, limit_id, settings)
  end

  defp check_threshold_alerts(state, nil, _limit_id, _settings), do: state

  defp check_threshold_alerts(state, bucket, limit_id, settings) when is_map(bucket) do
    remaining = map_get_any(bucket, ["remaining", :remaining])
    limit = map_get_any(bucket, ["limit", :limit])

    reset_in =
      map_get_any(bucket, [
        "reset_in_seconds",
        :reset_in_seconds,
        "resetInSeconds",
        :resetInSeconds,
        "reset_at",
        :reset_at
      ])

    if is_number(remaining) and is_number(limit) and limit > 0 do
      pct_used = (limit - remaining) / limit
      Enum.reduce(settings.thresholds, state, &maybe_threshold_alert(&2, &1, pct_used, limit_id, reset_in, settings))
    else
      state
    end
  end

  defp maybe_threshold_alert(state, threshold, pct_used, limit_id, reset_in, settings) do
    if pct_used >= threshold do
      pct_int = trunc(threshold * 100)
      key = "rate_limit:#{limit_id}:#{pct_int}pct"
      text = threshold_text(pct_int, limit_id, format_reset_time(reset_in))
      {_, new_state} = notify_with_debounce(state, key, text, settings)
      new_state
    else
      state
    end
  end

  defp handle_retry_alert(state, issue_id, identifier, attempt, error) do
    settings = alerts_settings()

    if settings.enabled and attempt >= settings.max_retry_attempts do
      label = if is_binary(identifier), do: identifier, else: issue_id
      error_str = if is_binary(error), do: ", last: #{error}", else: ""
      text = "🔵 Smithy: #{label} stuck in retry queue (#{attempt} attempts#{error_str})"
      {_, new_state} = notify_with_debounce(state, "retry:#{issue_id}", text, settings)
      new_state
    else
      state
    end
  end

  defp notify_with_debounce(state, key, text, settings) do
    now_ms = System.monotonic_time(:millisecond)
    last_sent_ms = Map.get(state.debounce, key)
    debounce_ms = settings.debounce_seconds * 1_000

    if is_nil(last_sent_ms) or now_ms - last_sent_ms >= debounce_ms do
      Logger.info("[Alerts] Sending alert key=#{key}")
      _ = Telegram.send(text)
      new_state = %{state | debounce: Map.put(state.debounce, key, now_ms)}
      {:sent, new_state}
    else
      {:debounced, state}
    end
  end

  defp alerts_settings do
    Config.settings!().alerts
  rescue
    _ -> %Schema.Alerts{}
  end

  defp bucket_exhausted?(primary, credits) do
    primary_exhausted =
      is_map(primary) and
        (fn ->
           remaining = map_get_any(primary, ["remaining", :remaining])
           is_integer(remaining) and remaining == 0
         end).()

    credits_exhausted =
      is_map(credits) and
        (fn ->
           has_credits = map_get_any(credits, ["has_credits", :has_credits])
           has_credits == false
         end).()

    primary_exhausted or credits_exhausted
  end

  defp threshold_text(pct, limit_id, reset_str) when pct >= 80 do
    "🔴 Smithy warning: #{limit_id} usage at #{pct}%#{reset_str}"
  end

  defp threshold_text(pct, limit_id, reset_str) do
    "🟡 Smithy warning: #{limit_id} usage at #{pct}%#{reset_str}"
  end

  defp format_reset_time(nil), do: ""

  defp format_reset_time(seconds) when is_number(seconds) do
    reset_at = DateTime.utc_now() |> DateTime.add(trunc(seconds), :second)
    formatted = Calendar.strftime(reset_at, "%H:%M UTC")
    " (resets at #{formatted})"
  end

  defp format_reset_time(_), do: ""

  defp map_get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_get_any(_, _), do: nil

  defp monitor_orchestrator do
    case Process.whereis(SymphonyElixir.Orchestrator) do
      nil -> :ok
      pid -> Process.monitor(pid)
    end
  end
end
