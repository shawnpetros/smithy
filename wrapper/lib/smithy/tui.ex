defmodule Smithy.TUI do
  @moduledoc """
  Renders the aggregate Smithy status TUI to stdout.

  Layout per `v2/SPEC.md` § "Smithy wrapper" > "Aggregate TUI":

      SMITHY STATUS
      Repos: 3 active / 3 registered
      Total Agents: 27/100   Throughput: ... tps   Uptime: ...
      Tokens (all repos): in 142M  |  out 8.3M  |  total 150M

      [slug]  19/50 agents  658k tps  http://localhost:4001
        MT-725  Todo         1m 19s  1,442,520 tok  command output streaming
        ...
  """

  alias Smithy.Status

  @divider String.duplicate("─", 74)

  @doc """
  Returns the rendered TUI as a string (no ANSI when `color: false`).
  """
  @spec render(Status.aggregate(), keyword()) :: String.t()
  def render(aggregate, opts \\ []) do
    color? = Keyword.get(opts, :color, true)

    [
      header(aggregate, color?),
      "",
      @divider,
      "",
      Enum.map_join(aggregate.repos, "\n\n", &render_repo(&1, color?)),
      "",
      @divider,
      "",
      footer(aggregate)
    ]
    |> Enum.join("\n")
  end

  defp header(agg, color?) do
    title = bold("⚒  SMITHY STATUS", color?)
    t = agg.totals

    [
      title,
      "Repos: #{t.active} active / #{t.registered} registered",
      "Total Agents: #{t.agents_running}",
      "Tokens (all repos): in #{humanize(t.tokens_in)}  |  out #{humanize(t.tokens_out)}  |  total #{humanize(t.tokens_total)}",
      "Generated: #{agg.generated_at}"
    ]
    |> Enum.join("\n")
  end

  defp footer(agg) do
    "Repos online: #{agg.totals.active}/#{agg.totals.registered}"
  end

  defp render_repo(%{status: :offline} = r, color?) do
    label = "[#{r.slug}]"
    offline = color(red(label, color?), color?)
    "#{offline}  OFFLINE  #{r.url}  (daemon down)"
  end

  defp render_repo(%{status: :online} = r, color?) do
    payload = r.payload || %{}
    running = payload["running"] || []
    counts = payload["counts"] || %{}
    n_running = counts["running"] || length(running)

    header_line =
      "#{green("[#{r.slug}]", color?)}  #{n_running} agents  #{r.url}"

    rows =
      running
      |> Enum.map(&row(&1, color?))
      |> case do
        [] -> ["  (no active agents)"]
        list -> list
      end

    Enum.join([header_line | rows], "\n")
  end

  defp row(entry, color?) do
    id = entry["issue_identifier"] || entry["issue_id"] || "?"
    state = entry["state"] || "?"
    tokens = get_in(entry, ["tokens", "total_tokens"]) || 0
    last = entry["last_event"] || entry["last_message"] || ""
    started = entry["started_at"]
    age = format_age(started)

    "  #{pad(id, 8)}  #{pad(state, 14)}  #{pad(age, 8)}  #{pad(number(tokens), 12)} tok  #{summary(last, color?)}"
  end

  defp pad(value, width) do
    s = to_string(value)
    s <> String.duplicate(" ", max(0, width - String.length(s)))
  end

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp number(n), do: to_string(n)

  defp humanize(n) when is_integer(n) and n >= 1_000_000_000 do
    "#{Float.round(n / 1_000_000_000, 1)}B"
  end

  defp humanize(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp humanize(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  defp humanize(n), do: to_string(n)

  defp summary(nil, _color?), do: ""
  defp summary(text, _color?) when is_binary(text), do: String.slice(text, 0, 60)
  defp summary(other, _color?), do: inspect(other) |> String.slice(0, 60)

  defp format_age(nil), do: ""

  defp format_age(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)
        humanize_seconds(diff)

      _ ->
        ""
    end
  end

  defp humanize_seconds(s) when s < 0, do: "0s"
  defp humanize_seconds(s) when s < 60, do: "#{s}s"

  defp humanize_seconds(s) when s < 3600 do
    m = div(s, 60)
    r = rem(s, 60)
    "#{m}m #{r}s"
  end

  defp humanize_seconds(s) do
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    "#{h}h #{m}m"
  end

  defp bold(s, true), do: IO.ANSI.bright() <> s <> IO.ANSI.reset()
  defp bold(s, false), do: s

  defp green(s, true), do: IO.ANSI.green() <> s <> IO.ANSI.reset()
  defp green(s, false), do: s

  defp red(s, true), do: IO.ANSI.red() <> s <> IO.ANSI.reset()
  defp red(s, false), do: s

  defp color(s, _), do: s
end
