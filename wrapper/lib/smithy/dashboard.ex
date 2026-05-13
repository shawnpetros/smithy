defmodule Smithy.Dashboard do
  @moduledoc """
  `smithy dashboard [slug]` launches a browser at the appropriate URL.

  - No slug: aggregate dashboard. Fetches live state from every registered
    daemon, renders a real HTML page to `~/.smithy/dashboard.html`, opens it,
    then keeps refreshing the file every 5 s so the browser's meta-refresh
    picks up new data.
  - With slug: opens `http://localhost:<port>/` for that repo's Symphony LiveView.
  """

  alias Smithy.{Color, Config, Status}

  @type opener :: (String.t() -> {String.t(), non_neg_integer()})

  @doc """
  Builds the aggregate dashboard HTML from a `Status.aggregate()` struct. Pure.
  """
  @spec aggregate_html(Status.aggregate()) :: String.t()
  def aggregate_html(aggregate) do
    totals = aggregate.totals
    repos = aggregate.repos
    generated_at = aggregate.generated_at

    header_html = render_header(totals, generated_at)
    global_metrics_html = if length(repos) != 1, do: render_global_metrics(totals), else: ""
    body_html = render_repos(repos)

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta http-equiv="refresh" content="5">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Smithy Dashboard</title>
      <style>
        #{inline_css()}
      </style>
    </head>
    <body>
      <div class="app-shell">
        <div class="dashboard-shell">
          #{header_html}
          #{global_metrics_html}
          #{body_html}
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Fetches live state from all daemons in `config`, renders the dashboard HTML,
  and writes it to `~/.smithy/dashboard.html`. Returns the file path on success.
  """
  @spec write_aggregate_html(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def write_aggregate_html(config) do
    aggregate = Status.collect(config)
    write_aggregate_html(config, aggregate)
  end

  @doc """
  Same as `write_aggregate_html/1` but accepts a pre-collected aggregate.
  Useful for testing without live HTTP calls.
  """
  @spec write_aggregate_html(Config.t(), Status.aggregate()) :: {:ok, String.t()} | {:error, term()}
  def write_aggregate_html(_config, aggregate) do
    path = Path.expand("~/.smithy/dashboard.html")
    body = aggregate_html(aggregate)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body) do
      {:ok, path}
    end
  end

  @doc """
  Opens a URL (or file path) using the platform-appropriate launcher.
  """
  @spec open(String.t(), opener()) :: {:ok, String.t()} | {:error, term()}
  def open(target, opener \\ &default_opener/1) do
    case opener.(target) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {out, status}}
    end
  end

  defp default_opener(target) do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> "open"
        _ -> "xdg-open"
      end

    System.cmd(cmd, [target], stderr_to_stdout: true)
  end

  # ---------------------------------------------------------------------------
  # HTML renderers
  # ---------------------------------------------------------------------------

  defp render_header(totals, generated_at) do
    active = totals.active
    registered = totals.registered
    offline = registered - active
    agents = totals.agents_running

    capacity_suffix =
      case totals.agents_capacity do
        nil -> ""
        cap -> "/#{format_int(cap)}"
      end

    time_part = String.slice(generated_at, 11, 8)

    """
    <header class="hero-card">
      <div class="hero-grid">
        <div>
          <p class="eyebrow">Smithy Aggregate Dashboard</p>
          <h1 class="hero-title">Operations</h1>
          <p class="hero-copy">
            #{active} active / #{registered} registered
            &nbsp;·&nbsp; #{agents}#{capacity_suffix} agents
            &nbsp;·&nbsp; #{format_int(totals.tokens_total)} tokens
            &nbsp;·&nbsp; #{format_tps(totals.throughput_tps)} tps
          </p>
        </div>
        <div class="status-stack">
          <span class="status-badge">
            <span class="status-badge-dot #{if offline > 0, do: "dot-warning", else: "dot-ok"}"></span>
            #{active}/#{registered} online
          </span>
          <p class="updated-at">updated #{time_part} UTC</p>
        </div>
      </div>
    </header>
    """
  end

  defp render_global_metrics(totals) do
    capacity_detail =
      case totals.agents_capacity do
        nil -> "No capacity limit configured."
        cap -> "#{cap} max across repos."
      end

    """
    <section class="metric-grid">
      <article class="metric-card">
        <p class="metric-label">Agents running</p>
        <p class="metric-value numeric">#{totals.agents_running}</p>
        <p class="metric-detail">#{capacity_detail}</p>
      </article>
      <article class="metric-card">
        <p class="metric-label">Total tokens</p>
        <p class="metric-value numeric">#{format_int(totals.tokens_total)}</p>
        <p class="metric-detail">#{format_int(totals.tokens_in)} in / #{format_int(totals.tokens_out)} out</p>
      </article>
      <article class="metric-card">
        <p class="metric-label">Throughput</p>
        <p class="metric-value numeric">#{format_tps(totals.throughput_tps)}</p>
        <p class="metric-detail">tokens per second across repos</p>
      </article>
      <article class="metric-card">
        <p class="metric-label">Repos</p>
        <p class="metric-value numeric">#{totals.active}/#{totals.registered}</p>
        <p class="metric-detail">#{totals.registered - totals.active} offline</p>
      </article>
    </section>
    """
  end

  defp render_repos([]) do
    """
    <section class="empty-card section-card">
      <p class="empty-title">No repos registered</p>
      <p class="empty-copy">Add one with <code>smithy add-repo &lt;path&gt;</code></p>
    </section>
    """
  end

  defp render_repos(repos) do
    repos
    |> Enum.map(&render_repo/1)
    |> Enum.join("\n")
  end

  defp render_repo(%{status: :offline, slug: slug, port: port}) do
    hue = Color.slug_css_hue(slug)
    safe_slug = escape_html(slug)

    """
    <section class="repo-section" style="--repo-h: #{hue}">
      <div class="section-card repo-card repo-offline">
        <header class="section-header">
          <div>
            <p class="eyebrow repo-eyebrow">#{safe_slug}</p>
            <h2 class="section-title">#{safe_slug}</h2>
            <p class="section-copy mono">http://localhost:#{port}/</p>
          </div>
          <span class="status-badge status-badge-offline">
            <span class="status-badge-dot"></span>
            Offline
          </span>
        </header>
        <p class="offline-message">Daemon unreachable. Start it with <code>smithy start #{safe_slug}</code></p>
      </div>
    </section>
    """
  end

  defp render_repo(%{status: :online, slug: slug, port: port, payload: payload}) do
    hue = Color.slug_css_hue(slug)
    safe_slug = escape_html(slug)
    running = get_in(payload, ["running"]) || []
    retrying = get_in(payload, ["retrying"]) || []
    counts = get_in(payload, ["counts"]) || %{}
    running_count = counts["running"] || length(running)
    retrying_count = counts["retrying"] || length(retrying)
    codex_totals = payload["codex_totals"] || %{}
    total_tokens = codex_totals["total_tokens"] || 0

    agent_table = render_running_table(running)
    retry_table = if retrying_count > 0, do: render_retry_table(retrying), else: ""

    """
    <section class="repo-section" style="--repo-h: #{hue}">
      <div class="section-card repo-card">
        <header class="section-header">
          <div>
            <p class="eyebrow repo-eyebrow">#{safe_slug}</p>
            <h2 class="section-title">#{safe_slug}</h2>
            <p class="section-copy mono">http://localhost:#{port}/</p>
          </div>
          <span class="status-badge status-badge-live">
            <span class="status-badge-dot"></span>
            Live
          </span>
        </header>

        <div class="repo-metric-row">
          <span class="repo-metric"><strong>#{running_count}</strong> running</span>
          <span class="repo-metric"><strong>#{retrying_count}</strong> retrying</span>
          <span class="repo-metric"><strong>#{format_int(total_tokens)}</strong> tokens</span>
        </div>

        #{agent_table}
        #{retry_table}
      </div>
    </section>
    """
  end

  defp render_repo(repo), do: render_repo(Map.put(repo, :status, :offline))

  defp render_running_table([]) do
    "<p class=\"empty-agents\">No active agents.</p>"
  end

  defp render_running_table(running) do
    rows =
      running
      |> Enum.map(fn entry ->
        id = entry["issue_identifier"] || entry["issue_id"] || "?"
        state = entry["state"] || "unknown"
        session = compact_session(entry["session_id"])
        tokens = get_in(entry, ["tokens", "total_tokens"]) || 0
        age = age_string(entry["started_at"])
        event = entry["last_message"] || entry["last_event"] || "none"

        badge_class = state_badge_class(state)

        """
        <tr>
          <td class="td-id"><span class="issue-id">#{escape_html(id)}</span></td>
          <td><span class="state-badge #{badge_class}">#{escape_html(state)}</span></td>
          <td class="mono td-session">#{escape_html(session)}</td>
          <td class="numeric td-tokens">#{format_int(tokens)}</td>
          <td class="td-age">#{escape_html(age)}</td>
          <td class="td-event">#{escape_html(event)}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    """
    <div class="table-wrap">
      <table class="data-table">
        <thead>
          <tr>
            <th>Issue</th>
            <th>State</th>
            <th>Session</th>
            <th class="numeric">Tokens</th>
            <th>Age</th>
            <th>Last event</th>
          </tr>
        </thead>
        <tbody>
          #{rows}
        </tbody>
      </table>
    </div>
    """
  end

  defp render_retry_table(retrying) do
    rows =
      retrying
      |> Enum.map(fn entry ->
        id = entry["issue_identifier"] || entry["issue_id"] || "?"
        attempt = entry["attempt"] || 1
        due = entry["due_at"] || "pending"
        error = truncate(entry["error"] || "", 80)

        """
        <tr>
          <td class="td-id"><span class="issue-id">#{escape_html(id)}</span></td>
          <td class="numeric">##{attempt}</td>
          <td class="mono">#{escape_html(due)}</td>
          <td class="td-event">#{escape_html(error)}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    """
    <div class="table-wrap" style="margin-top: 1rem">
      <p class="section-sublabel">Retry queue</p>
      <table class="data-table">
        <thead>
          <tr>
            <th>Issue</th>
            <th class="numeric">Attempt</th>
            <th>Due at</th>
            <th>Error</th>
          </tr>
        </thead>
        <tbody>
          #{rows}
        </tbody>
      </table>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp state_badge_class(state) do
    case String.downcase(to_string(state)) do
      s when s in ["in_progress", "in progress", "active", "running"] -> "state-badge-active"
      s when s in ["retrying", "warning"] -> "state-badge-warning"
      s when s in ["failed", "error", "cancelled"] -> "state-badge-danger"
      _ -> "state-badge-neutral"
    end
  end

  defp compact_session(nil), do: "none"
  defp compact_session(s) when byte_size(s) <= 10, do: s
  defp compact_session(s), do: String.slice(s, 0, 8) <> ".."

  defp age_string(nil), do: ""

  defp age_string(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        seconds = max(0, DateTime.diff(DateTime.utc_now(), dt, :second))
        format_duration(seconds)

      _ ->
        ""
    end
  end

  defp format_duration(s) when s < 60, do: "#{s}s"
  defp format_duration(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp format_duration(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp format_int(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_int(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}k"

  defp format_int(n) when is_integer(n), do: Integer.to_string(n)
  defp format_int(_), do: "0"

  defp format_tps(tps) when is_float(tps), do: Float.round(tps, 1) |> Float.to_string()
  defp format_tps(tps) when is_integer(tps), do: Integer.to_string(tps)
  defp format_tps(_), do: "0"

  defp truncate(s, max_len) when byte_size(s) > max_len,
    do: String.slice(s, 0, max_len - 1) <> "..."

  defp truncate(s, _), do: s

  defp escape_html(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # ---------------------------------------------------------------------------
  # Inline CSS
  # ---------------------------------------------------------------------------

  defp inline_css do
    """
    :root {
      color-scheme: light;
      --page: #f7f7f8;
      --page-soft: #fbfbfc;
      --card: rgba(255,255,255,0.94);
      --card-muted: #f3f4f6;
      --ink: #202123;
      --muted: #6e6e80;
      --line: #ececf1;
      --line-strong: #d9d9e3;
      --accent: #10a37f;
      --accent-ink: #0f513f;
      --accent-soft: #e8faf4;
      --danger: #b42318;
      --danger-soft: #fef3f2;
      --shadow-sm: 0 1px 2px rgba(16,24,40,0.05);
      --shadow-lg: 0 20px 50px rgba(15,23,42,0.08);
    }
    *{box-sizing:border-box}
    html{background:var(--page)}
    body{
      margin:0;min-height:100vh;
      background:radial-gradient(circle at top,rgba(16,163,127,0.10) 0%,rgba(16,163,127,0) 30%),
                 linear-gradient(180deg,var(--page-soft) 0%,var(--page) 24%,#f3f4f6 100%);
      color:var(--ink);
      font-family:"SF Pro Text","Helvetica Neue","Segoe UI",sans-serif;
      line-height:1.5
    }
    code,pre,.mono{font-family:"SFMono-Regular","SF Mono",Consolas,"Liberation Mono",monospace}
    .numeric{font-variant-numeric:tabular-nums slashed-zero}
    .app-shell{max-width:1280px;margin:0 auto;padding:2rem 1rem 3.5rem}
    .dashboard-shell{display:grid;gap:1rem}

    /* hero card */
    .hero-card,.section-card,.metric-card{
      background:var(--card);
      border:1px solid rgba(217,217,227,0.82);
      box-shadow:var(--shadow-sm);
      backdrop-filter:blur(18px)
    }
    .hero-card{border-radius:28px;padding:clamp(1.25rem,3vw,2rem);box-shadow:var(--shadow-lg)}
    .hero-grid{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:1.25rem;align-items:start}
    .eyebrow{margin:0;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;font-size:.76rem;font-weight:600}
    .hero-title{margin:.35rem 0 0;font-size:clamp(2rem,4vw,3.3rem);line-height:.98;letter-spacing:-.04em}
    .hero-copy{margin:.75rem 0 0;max-width:46rem;color:var(--muted);font-size:1rem}
    .status-stack{display:grid;justify-items:end;align-content:start;gap:.4rem;min-width:min(100%,9rem)}
    .updated-at{margin:0;color:var(--muted);font-size:.76rem}

    /* status badge */
    .status-badge{
      display:inline-flex;align-items:center;gap:.45rem;
      min-height:2rem;padding:.35rem .78rem;border-radius:999px;
      border:1px solid var(--line);background:var(--card-muted);
      color:var(--muted);font-size:.82rem;font-weight:700;letter-spacing:.01em
    }
    .status-badge-dot{width:.52rem;height:.52rem;border-radius:999px;background:currentColor;opacity:.9}
    .dot-ok{color:var(--accent)}
    .dot-warning{color:#d97706}
    .status-badge-live{background:var(--accent-soft);border-color:rgba(16,163,127,.18);color:var(--accent-ink)}
    .status-badge-offline{background:#f5f5f7;border-color:var(--line-strong);color:var(--muted)}

    /* global metric grid */
    .metric-grid{display:grid;gap:.85rem;grid-template-columns:repeat(auto-fit,minmax(180px,1fr))}
    .metric-card{border-radius:22px;padding:1rem 1.05rem 1.1rem}
    .metric-label{margin:0;color:var(--muted);font-size:.82rem;font-weight:600;letter-spacing:.01em}
    .metric-value{margin:.35rem 0 0;font-size:clamp(1.6rem,2vw,2.1rem);line-height:1.05;letter-spacing:-.03em}
    .metric-detail{margin:.45rem 0 0;color:var(--muted);font-size:.88rem}

    /* repo sections */
    .repo-section{--repo-accent:hsl(var(--repo-h),65%,42%);--repo-accent-soft:hsl(var(--repo-h),65%,96%);--repo-accent-ink:hsl(var(--repo-h),65%,22%)}
    .section-card{border-radius:24px;padding:1.15rem}
    .section-header{display:flex;justify-content:space-between;align-items:flex-start;gap:1rem;flex-wrap:wrap;margin-bottom:.85rem}
    .section-title{margin:0;font-size:1.08rem;line-height:1.2;letter-spacing:-.02em}
    .section-copy{margin:.35rem 0 0;color:var(--muted);font-size:.94rem}
    .section-sublabel{margin:0 0 .4rem;color:var(--muted);font-size:.82rem;font-weight:600;text-transform:uppercase;letter-spacing:.04em}

    /* per-repo eyebrow uses repo accent */
    .repo-eyebrow{color:var(--repo-accent)}
    .repo-card .status-badge-live{
      background:var(--repo-accent-soft);
      border-color:color-mix(in srgb,var(--repo-accent) 30%,transparent);
      color:var(--repo-accent-ink)
    }

    /* repo metric pill row */
    .repo-metric-row{display:flex;gap:1.5rem;margin-bottom:.75rem;flex-wrap:wrap}
    .repo-metric{font-size:.94rem;color:var(--muted)}
    .repo-metric strong{color:var(--ink)}

    /* offline state */
    .repo-offline .section-header{opacity:.7}
    .offline-message{margin:.5rem 0 0;color:var(--muted);font-size:.94rem}

    /* tables */
    .table-wrap{overflow-x:auto}
    .data-table{width:100%;border-collapse:collapse;min-width:600px}
    .data-table th{padding:0 .5rem .75rem 0;text-align:left;color:var(--muted);font-size:.78rem;font-weight:600;text-transform:uppercase;letter-spacing:.04em}
    .data-table .numeric{text-align:right;padding-right:0}
    .data-table td{padding:.75rem .5rem .75rem 0;border-top:1px solid var(--line);vertical-align:top;font-size:.94rem}
    .td-id{min-width:6rem}
    .td-session{min-width:7rem}
    .td-tokens{text-align:right}
    .td-event{max-width:24rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .issue-id{font-weight:600}
    .empty-agents{margin:.5rem 0;color:var(--muted);font-size:.94rem}

    /* state badges */
    .state-badge{display:inline-block;padding:.15rem .5rem;border-radius:999px;font-size:.78rem;font-weight:600;letter-spacing:.01em}
    .state-badge-active{background:var(--accent-soft);color:var(--accent-ink)}
    .state-badge-warning{background:#fefce8;color:#854d0e}
    .state-badge-danger{background:var(--danger-soft);color:var(--danger)}
    .state-badge-neutral{background:var(--card-muted);color:var(--muted)}

    /* empty state */
    .empty-card{text-align:center;padding:3rem 1.5rem;border-radius:24px}
    .empty-title{margin:0;font-size:1.2rem;letter-spacing:-.02em}
    .empty-copy{margin:.5rem 0 0;color:var(--muted)}
    """
  end
end
