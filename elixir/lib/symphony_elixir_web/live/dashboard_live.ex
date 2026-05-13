defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @max_history_per_ticket 50

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()
    event_history = record_events(%{}, payload)

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:event_history, event_history)
      |> assign(:expanded_rows, MapSet.new())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    new_payload = load_payload()
    event_history = record_events(socket.assigns.event_history, new_payload)

    {:noreply,
     socket
     |> assign(:payload, new_payload)
     |> assign(:event_history, event_history)
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("toggle_row", %{"identifier" => identifier}, socket) do
    expanded_rows = socket.assigns.expanded_rows

    new_expanded_rows =
      if MapSet.member?(expanded_rows, identifier) do
        MapSet.delete(expanded_rows, identifier)
      else
        MapSet.put(expanded_rows, identifier)
      end

    {:noreply, assign(socket, :expanded_rows, new_expanded_rows)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <% cards = rate_limit_cards(@payload.rate_limits) %>
          <%= if cards in [:none, []] do %>
            <p class="muted empty-state">n/a</p>
          <% else %>
            <div class="rate-limit-grid">
              <%= for {label, window, credits} <- cards do %>
                <.rl_card label={label} window={window} credits={credits} />
              <% end %>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Runtime update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for entry <- @payload.running do %>
                    <tr>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= entry.state %>
                        </span>
                      </td>
                      <td>
                        <div class="session-stack">
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy ID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              Copy ID
                            </button>
                          <% else %>
                            <span class="muted">n/a</span>
                          <% end %>
                        </div>
                      </td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <div class="runtime-update-header">
                            <span
                              class="event-text"
                              title={entry.last_message || to_string(entry.last_event || "n/a")}
                            ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                            <button
                              type="button"
                              class={"caret-button #{if MapSet.member?(@expanded_rows, entry.issue_identifier), do: "caret-button-open", else: ""}"}
                              phx-click="toggle_row"
                              phx-value-identifier={entry.issue_identifier}
                              title={if MapSet.member?(@expanded_rows, entry.issue_identifier), do: "Collapse history", else: "Expand history"}
                            >&#9654;</button>
                          </div>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              &middot; <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                    </tr>
                    <%= if MapSet.member?(@expanded_rows, entry.issue_identifier) do %>
                      <tr class="history-row">
                        <td colspan="6" class="history-cell">
                          <div class="event-history-panel">
                            <%= if Map.get(@event_history, entry.issue_identifier, []) == [] do %>
                              <p class="muted history-empty">No events recorded yet.</p>
                            <% else %>
                              <%= for event <- Map.get(@event_history, entry.issue_identifier, []) do %>
                                <div class={"event-history-row #{event_type_class(event.event)}"}>
                                  <span class="event-history-time mono numeric"><%= event.at || "-" %></span>
                                  <span class="event-history-type"><%= event.event || "-" %></span>
                                  <span class="event-history-msg"><%= event.message || "-" %></span>
                                </div>
                              <% end %>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  @spec rl_card(map()) :: Phoenix.LiveView.Rendered.t()
  def rl_card(assigns) do
    ~H"""
    <% status = rl_status(@window, @credits) %>
    <% pct = rl_pct_used(@window) %>
    <div class={"rl-card rl-card-#{status}"}>
      <p class="rl-card-label"><%= @label %></p>
      <%= if is_map(@window) do %>
        <p class="rl-card-status">
          <%= status %>
          <%= if pct do %>
            <span class="rl-card-pct">(<%= pct %>% used)</span>
          <% end %>
        </p>
        <p class="rl-card-detail">
          Resets in: <span class="mono"><%= format_reset_in(rl_get(@window, :reset_in_seconds)) %></span>
        </p>
        <p class="rl-card-detail">
          <%= rl_get(@window, :remaining) || "n/a" %> / <%= rl_get(@window, :limit) || "n/a" %> remaining
        </p>
        <%= if @credits do %>
          <p class="rl-card-detail">Credits: <%= format_credits(@credits) %></p>
        <% end %>
      <% else %>
        <p class="muted">n/a</p>
      <% end %>
    </div>
    """
  end

  defp rate_limit_cards(nil), do: :none

  defp rate_limit_cards(rl) when is_map(rl) do
    if Map.has_key?(rl, :codex) or Map.has_key?(rl, "codex") do
      codex = Map.get(rl, :codex) || Map.get(rl, "codex")
      claude = Map.get(rl, :claude_code) || Map.get(rl, "claude_code")
      [{"codex", codex, nil}, {"claude_code", claude, nil}]
    else
      primary = Map.get(rl, :primary) || Map.get(rl, "primary")
      secondary = Map.get(rl, :secondary) || Map.get(rl, "secondary")
      limit_id = Map.get(rl, :limit_id) || Map.get(rl, "limit_id")
      credits = Map.get(rl, :credits) || Map.get(rl, "credits")

      []
      |> maybe_add_card(primary, rl_label(limit_id, "primary"), credits)
      |> maybe_add_card(secondary, rl_label(limit_id, "secondary"), nil)
    end
  end

  defp maybe_add_card(cards, nil, _label, _credits), do: cards
  defp maybe_add_card(cards, window, label, credits), do: cards ++ [{label, window, credits}]

  defp rl_label(nil, suffix), do: suffix
  defp rl_label(id, suffix), do: "#{id} · #{suffix}"

  defp rl_get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp rl_pct_used(window) when is_map(window) do
    remaining = rl_get(window, :remaining)
    limit = rl_get(window, :limit)

    if is_number(remaining) and is_number(limit) and limit > 0 do
      trunc((limit - remaining) / limit * 100)
    else
      nil
    end
  end

  defp rl_pct_used(_), do: nil

  defp rl_status(window, credits) when is_map(window) do
    pct = rl_pct_used(window)
    remaining = rl_get(window, :remaining)
    has_credits = if is_map(credits), do: rl_get(credits, :has_credits), else: true

    cond do
      remaining == 0 -> "exhausted"
      has_credits == false -> "exhausted"
      is_integer(pct) && pct >= 80 -> "approaching"
      true -> "allowed"
    end
  end

  defp rl_status(_window, _credits), do: "allowed"

  defp format_reset_in(nil), do: "unknown"

  defp format_reset_in(seconds) when is_number(seconds) do
    s = trunc(seconds)

    cond do
      s >= 3600 ->
        h = div(s, 3600)
        m = div(rem(s, 3600), 60)
        "#{h}h #{m}m"

      s >= 60 ->
        m = div(s, 60)
        sec = rem(s, 60)
        "#{m}m #{sec}s"

      true ->
        "#{s}s"
    end
  end

  defp format_reset_in(_), do: "unknown"

  defp format_credits(credits) when is_map(credits) do
    unlimited = rl_get(credits, :unlimited)
    has_credits = rl_get(credits, :has_credits)
    balance = rl_get(credits, :balance)

    cond do
      unlimited == true -> "unlimited"
      has_credits == false -> "exhausted"
      is_number(balance) -> "$#{:erlang.float_to_binary(balance * 1.0, [{:decimals, 2}])}"
      has_credits == true -> "available"
      true -> "n/a"
    end
  end

  defp format_credits(_), do: "n/a"

  defp event_type_class(event) do
    s = to_string(event || "")

    cond do
      String.contains?(s, ["turn_completed", "completed"]) -> "event-completed"
      String.contains?(s, ["error", "failed", "crash"]) -> "event-error"
      String.contains?(s, ["turn_started", "started"]) -> "event-started"
      true -> ""
    end
  end

  defp record_events(event_history, %{running: running}) when is_list(running) do
    Enum.reduce(running, event_history, fn entry, acc ->
      id = entry.issue_identifier
      history = Map.get(acc, id, [])

      new_event = %{
        at: entry.last_event_at,
        event: entry.last_event,
        message: entry.last_message
      }

      if is_nil(new_event.event) ||
           (history != [] &&
              hd(history).at == new_event.at &&
              hd(history).event == new_event.event) do
        acc
      else
        Map.put(acc, id, [new_event | history] |> Enum.take(@max_history_per_ticket))
      end
    end)
  end

  defp record_events(event_history, _payload), do: event_history

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now)
       when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now)
       when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
