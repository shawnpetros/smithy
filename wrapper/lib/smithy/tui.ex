defmodule Smithy.TUI do
  @moduledoc """
  Renders and runs the aggregate Smithy status TUI.

  The renderer intentionally stays hand-rolled, matching Symphony's terminal
  dashboard style without adding an external TUI dependency.
  """

  alias Smithy.{Color, Config, Status}

  @default_columns 115
  @min_columns 80
  @default_rows 32
  @min_scroll_rows 3
  @ansi_escape ~r/\e\[[0-9;?]*[[:alpha:]]/

  @running_id_width 8
  @running_stage_width 14
  @running_pid_width 8
  @running_age_width 12
  @running_tokens_width 10
  @running_session_width 14
  @running_event_min_width 12

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_red IO.ANSI.red()

  @type render_opts :: keyword() | map()
  @type run_opts :: keyword() | map()

  @doc """
  Returns the rendered aggregate TUI frame as a string.
  """
  @spec render(Status.aggregate(), render_opts()) :: String.t()
  def render(aggregate, opts \\ []) do
    color? = option(opts, :color, true)
    columns = option(opts, :columns, terminal_columns()) |> normalize_columns()
    rows = option(opts, :terminal_rows, nil)
    scroll_offset = option(opts, :scroll_offset, 0) |> max(0)
    next_refresh_seconds = option(opts, :next_refresh_seconds, 1)
    help? = option(opts, :help?, false)

    header_lines = aggregate_header_lines(aggregate, columns, next_refresh_seconds, color?)
    content_lines = content_lines(aggregate, columns, color?)
    help_line = help_line(columns, help?)

    visible_content =
      case rows do
        row_count when is_integer(row_count) and row_count > 0 ->
          reserved_rows = 2 + length(header_lines) + 1
          available_rows = max(@min_scroll_rows, row_count - reserved_rows)
          Enum.slice(content_lines, scroll_offset, available_rows)

        _ ->
          content_lines
      end

    [
      title_border("SMITHY STATUS", columns, color?),
      header_lines,
      visible_content,
      help_line,
      bottom_border(columns)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc """
  Runs the interactive status TUI until the operator quits.
  """
  @spec run(Config.t(), run_opts()) :: :ok | {:error, term()}
  def run(config, opts \\ []) do
    interval_ms = option(opts, :interval_ms, 1_000)
    color? = option(opts, :color, color?())
    collect = option(opts, :collect, &Status.collect/1)
    capture_stty_fun = option(opts, :capture_stty, &capture_stty/0)
    enter_terminal_fun = option(opts, :enter_terminal, &enter_terminal/0)
    restore_terminal_fun = option(opts, :restore_terminal, &restore_terminal/1)
    old_stty = capture_stty_fun.()

    try do
      enter_terminal_fun.()

      loop(%{
        config: config,
        collect: collect,
        interval_ms: interval_ms,
        color?: color?,
        scroll_offset: 0,
        help?: false,
        previous_sample: nil,
        tty?: not is_nil(old_stty),
        terminal_size: option(opts, :terminal_size, &terminal_size/0),
        write_frame: option(opts, :write_frame, &write_frame/1),
        read_key: option(opts, :read_key, &wait_for_key/2)
      })
    after
      restore_terminal_fun.(old_stty)
    end
  end

  defp loop(state) do
    now_ms = System.monotonic_time(:millisecond)
    aggregate = state.collect.(state.config)
    {throughput_tps, sample} = throughput(state.previous_sample, aggregate, now_ms)
    aggregate = put_total(aggregate, :throughput_tps, throughput_tps)
    {columns, rows} = state.terminal_size.()

    frame =
      render(aggregate,
        color: state.color?,
        columns: columns,
        terminal_rows: rows,
        scroll_offset: state.scroll_offset,
        help?: state.help?,
        next_refresh_seconds: div(state.interval_ms + 999, 1_000)
      )

    state.write_frame.(frame)

    case state.read_key.(state.interval_ms, state.tty?) do
      :quit ->
        :ok

      :refresh ->
        loop(%{state | previous_sample: sample})

      :help ->
        loop(%{state | help?: not state.help?, previous_sample: sample})

      :up ->
        loop(%{state | scroll_offset: max(0, state.scroll_offset - 1), previous_sample: sample})

      :down ->
        loop(%{state | scroll_offset: state.scroll_offset + 1, previous_sample: sample})

      _ ->
        loop(%{state | previous_sample: sample})
    end
  end

  defp aggregate_header_lines(aggregate, columns, next_refresh_seconds, color?) do
    totals = Map.get(aggregate, :totals, %{})
    registered = total_value(totals, :registered, 0)
    active = total_value(totals, :active, 0)
    running = total_value(totals, :agents_running, 0)
    capacity = total_value(totals, :agents_capacity, nil) || "?"
    throughput = total_value(totals, :throughput_tps, 0)
    tokens_in = total_value(totals, :tokens_in, 0)
    tokens_out = total_value(totals, :tokens_out, 0)
    tokens_total = total_value(totals, :tokens_total, 0)
    generated_at = Map.get(aggregate, :generated_at, "n/a")

    [
      content_line(
        label("Repos:", color?) <> " #{active} active / #{registered} registered",
        columns
      ),
      content_line(
        label("Total Agents:", color?) <> " #{running}/#{capacity} across repos",
        columns
      ),
      content_line(label("Throughput:", color?) <> " #{format_tps(throughput)} tps", columns),
      content_line(
        label("Tokens:", color?) <>
          " in #{format_count(tokens_in)} | out #{format_count(tokens_out)} | total #{format_count(tokens_total)}",
        columns
      ),
      content_line(label("Generated:", color?) <> " #{generated_at}", columns),
      content_line(label("Next refresh:", color?) <> " #{next_refresh_seconds}s", columns)
    ]
  end

  defp content_lines(aggregate, columns, color?) do
    repo_lines =
      aggregate
      |> Map.get(:repos, [])
      |> Enum.flat_map(&repo_lines(&1, columns, color?))

    repo_lines ++
      [section_line("Backoff queue", columns, color?), blank_line(columns)] ++
      backoff_lines(aggregate, columns)
  end

  defp repo_lines(%{status: :offline, slug: slug}, columns, color?) do
    slug_label =
      if color? do
        Color.slug_ansi_256(slug) <> @ansi_bold <> "[#{slug}] OFFLINE" <> @ansi_reset <>
          @ansi_red <> " — daemon down" <> @ansi_reset
      else
        "[#{slug}] OFFLINE — daemon down"
      end

    [
      section_line(slug_label, columns, false),
      content_line("  No table; daemon is unreachable", columns),
      blank_line(columns)
    ]
  end

  defp repo_lines(%{status: :online, slug: slug, payload: payload}, columns, color?) do
    payload = payload || %{}
    running = list_value(payload, ["running", :running])
    counts = map_value(payload, ["counts", :counts]) || %{}
    running_count = map_value(counts, ["running", :running]) || length(running)
    capacity = agent_capacity(payload)
    capacity_suffix = if capacity, do: "/#{capacity}", else: ""
    event_width = running_event_width(columns)

    slug_label =
      if color? do
        Color.slug_ansi_256(slug) <> @ansi_bold <> "[#{slug}] Running" <> @ansi_reset
      else
        "[#{slug}] Running"
      end

    rows =
      case running do
        [] ->
          [content_line("  No active agents", columns)]

        entries ->
          entries
          |> Enum.map(&running_row(&1, event_width))
          |> Enum.map(&content_line("  " <> &1, columns))
      end

    [
      section_line(slug_label, columns, false),
      content_line("  Agents: #{running_count}#{capacity_suffix}", columns),
      blank_line(columns),
      content_line("  " <> running_table_header(event_width), columns),
      content_line("  " <> running_table_separator(event_width), columns),
      rows,
      blank_line(columns)
    ]
    |> List.flatten()
  end

  defp repo_lines(%{slug: slug}, columns, color?) do
    repo_lines(%{status: :offline, slug: slug}, columns, color?)
  end

  defp running_row(entry, event_width) do
    tokens =
      map_value(map_value(entry, ["tokens", :tokens]) || %{}, ["total_tokens", :total_tokens]) ||
        0

    [
      format_cell(
        map_value(entry, ["issue_identifier", :issue_identifier, "issue_id", :issue_id]) || "?",
        @running_id_width
      ),
      format_cell(
        map_value(entry, ["state", :state, "stage", :stage]) || "unknown",
        @running_stage_width
      ),
      format_cell(
        map_value(entry, ["pid", :pid, "codex_app_server_pid", :codex_app_server_pid]) || "n/a",
        @running_pid_width
      ),
      format_cell(format_age_turn(entry), @running_age_width),
      format_count(tokens) |> format_cell(@running_tokens_width, :right),
      format_cell(
        compact_session_id(map_value(entry, ["session_id", :session_id])),
        @running_session_width
      ),
      format_cell(format_event(entry), event_width)
    ]
    |> Enum.join(" ")
  end

  defp running_table_header(event_width) do
    [
      format_cell("ID", @running_id_width),
      format_cell("STAGE", @running_stage_width),
      format_cell("PID", @running_pid_width),
      format_cell("AGE / TURN", @running_age_width),
      format_cell("TOKENS", @running_tokens_width),
      format_cell("SESSION", @running_session_width),
      format_cell("EVENT", event_width)
    ]
    |> Enum.join(" ")
  end

  defp running_table_separator(event_width) do
    width =
      @running_id_width +
        @running_stage_width +
        @running_pid_width +
        @running_age_width +
        @running_tokens_width +
        @running_session_width +
        event_width + 6

    String.duplicate("─", width)
  end

  defp backoff_lines(aggregate, columns) do
    retries =
      aggregate
      |> Map.get(:repos, [])
      |> Enum.flat_map(fn repo ->
        repo
        |> Map.get(:payload)
        |> case do
          payload when is_map(payload) ->
            payload
            |> list_value(["retrying", :retrying])
            |> Enum.map(&{repo.slug, &1})

          _ ->
            []
        end
      end)

    case retries do
      [] ->
        [content_line("  No queued retries", columns)]

      retry_entries ->
        Enum.map(retry_entries, fn {slug, retry} ->
          content_line("  ↻ [#{slug}] " <> retry_summary(retry), columns)
        end)
    end
  end

  defp retry_summary(retry) do
    identifier =
      map_value(retry, ["issue_identifier", :issue_identifier, "issue_id", :issue_id]) ||
        "unknown"

    attempt = map_value(retry, ["attempt", :attempt]) || 0
    due = map_value(retry, ["due_at", :due_at, "due_in_ms", :due_in_ms])
    error = map_value(retry, ["error", :error])

    [
      identifier,
      "attempt=#{attempt}",
      due && "due=#{due}",
      error && "error=#{sanitize(error)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp title_border(title, columns, color?) do
    title = colorize(title, @ansi_bold, color?)
    border_with_label("╭", "╮", title, columns)
  end

  defp section_line(title, columns, true),
    do: border_with_label("├", "┤", colorize(title, @ansi_bold, true), columns)

  defp section_line(title, columns, false), do: border_with_label("├", "┤", title, columns)

  defp border_with_label(left, right, label_text, columns) do
    prefix = "#{left}─ #{label_text} "
    fill = String.duplicate("─", max(0, columns - visible_length(prefix) - visible_length(right)))
    prefix <> fill <> right
  end

  defp content_line(text, columns) do
    inner_width = columns - 4
    fitted = fit(text, inner_width)
    "│ " <> fitted <> String.duplicate(" ", max(0, inner_width - visible_length(fitted))) <> " │"
  end

  defp blank_line(columns), do: content_line("", columns)
  defp bottom_border(columns), do: "╰" <> String.duplicate("─", columns - 2) <> "╯"

  defp help_line(columns, true) do
    content_line("↑/k scroll up • ↓/j scroll down • r refresh • ? hide help • q quit", columns)
  end

  defp help_line(columns, false) do
    content_line("↑/↓ scroll • r refresh • ? help • q quit", columns)
  end

  defp fit(text, width) do
    text = sanitize_line(text)

    if visible_length(text) <= width do
      text
    else
      truncate_plain(strip_ansi(text), width)
    end
  end

  defp format_age_turn(entry) do
    runtime_seconds =
      map_value(entry, ["runtime_seconds", :runtime_seconds, "seconds_running", :seconds_running]) ||
        seconds_since(map_value(entry, ["started_at", :started_at]))

    runtime = format_runtime_seconds(runtime_seconds)
    turns = map_value(entry, ["turn_count", :turn_count])

    if is_integer(turns) and turns > 0 do
      "#{runtime} / #{turns}"
    else
      runtime
    end
  end

  defp format_event(entry) do
    map_value(entry, ["last_message", :last_message, "last_event", :last_event]) || "none"
  end

  defp seconds_since(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> max(0, DateTime.diff(DateTime.utc_now(), datetime, :second))
      _ -> 0
    end
  end

  defp seconds_since(_), do: 0

  defp format_runtime_seconds(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_runtime_seconds(_), do: "0m 0s"

  defp compact_session_id(nil), do: "n/a"
  defp compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  defp compact_session_id(session_id) do
    if String.length(session_id) > 10 do
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
    end
  end

  defp agent_capacity(payload) when is_map(payload) do
    counts = map_value(payload, ["counts", :counts]) || %{}

    map_value(counts, ["max_agents", :max_agents, "max", :max, "capacity", :capacity]) ||
      map_value(payload, ["max_agents", :max_agents, "agent_capacity", :agent_capacity])
  end

  defp agent_capacity(_), do: nil

  defp throughput(nil, aggregate, now_ms),
    do: {total_value(aggregate.totals, :throughput_tps, 0), {now_ms, total_tokens(aggregate)}}

  defp throughput({previous_ms, previous_tokens}, aggregate, now_ms) do
    current_tokens = total_tokens(aggregate)
    elapsed_ms = max(0, now_ms - previous_ms)

    tps =
      if elapsed_ms == 0 do
        total_value(aggregate.totals, :throughput_tps, 0)
      else
        max(0, current_tokens - previous_tokens) / (elapsed_ms / 1_000)
      end

    {tps, {now_ms, current_tokens}}
  end

  defp total_tokens(aggregate), do: total_value(aggregate.totals, :tokens_total, 0)

  defp put_total(aggregate, key, value) do
    Map.update!(aggregate, :totals, &Map.put(&1, key, value))
  end

  defp format_tps(value) when is_float(value), do: value |> trunc() |> format_count()
  defp format_tps(value), do: format_count(value)

  defp format_count(nil), do: "0"
  defp format_count(value) when is_float(value), do: value |> trunc() |> format_count()

  defp format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  defp format_count(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {number, ""} -> format_count(number)
      _ -> value
    end
  end

  defp format_count(value), do: to_string(value)

  defp format_cell(value, width, align \\ :left) do
    value =
      value
      |> sanitize()
      |> truncate_plain(width)

    case align do
      :right -> String.pad_leading(value, width)
      _ -> String.pad_trailing(value, width)
    end
  end

  defp truncate_plain(value, width) when width <= 3, do: String.slice(value, 0, width)

  defp truncate_plain(value, width) do
    if String.length(value) <= width do
      value
    else
      String.slice(value, 0, width - 3) <> "..."
    end
  end

  defp group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    grouped =
      unsigned
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    sign <> grouped
  end

  defp running_event_width(columns) do
    fixed =
      @running_id_width +
        @running_stage_width +
        @running_pid_width +
        @running_age_width +
        @running_tokens_width +
        @running_session_width

    inner_width = columns - 4
    row_prefix_width = 2
    separator_width = 6

    max(@running_event_min_width, inner_width - row_prefix_width - fixed - separator_width)
  end

  defp map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  defp list_value(map, keys) do
    case map_value(map, keys) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp total_value(totals, key, default) when is_map(totals) do
    Map.get(totals, key) || Map.get(totals, to_string(key)) || default
  end

  defp total_value(_totals, _key, default), do: default

  defp label(text, true), do: colorize(text, @ansi_bold, true)
  defp label(text, false), do: text

  defp colorize(value, _code, false), do: value
  defp colorize(value, code, true), do: code <> value <> @ansi_reset

  defp sanitize(value) when is_binary(value) do
    value
    |> String.replace("\r\n", " ")
    |> String.replace("\r", " ")
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize(value), do: value |> inspect(limit: 10) |> sanitize()

  defp sanitize_line(value) when is_binary(value) do
    value
    |> String.replace("\r\n", " ")
    |> String.replace("\r", " ")
    |> String.replace("\n", " ")
  end

  defp sanitize_line(value), do: value |> inspect(limit: 10) |> sanitize_line()

  defp visible_length(value) do
    value
    |> strip_ansi()
    |> String.length()
  end

  defp strip_ansi(value), do: String.replace(value, @ansi_escape, "")

  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp option(_opts, _key, default), do: default

  defp normalize_columns(columns) when is_integer(columns), do: max(@min_columns, columns)
  defp normalize_columns(_), do: @default_columns

  defp color?, do: System.get_env("NO_COLOR") in [nil, ""] and IO.ANSI.enabled?()

  defp terminal_size do
    {terminal_columns(), terminal_rows()}
  end

  defp terminal_columns do
    case :io.columns() do
      {:ok, columns} when is_integer(columns) and columns > 0 -> columns
      _ -> env_integer("COLUMNS", @default_columns)
    end
  end

  defp terminal_rows do
    case :io.rows() do
      {:ok, rows} when is_integer(rows) and rows > 0 -> rows
      _ -> env_integer("LINES", @default_rows)
    end
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} when integer > 0 -> integer
          _ -> default
        end
    end
  end

  defp write_frame(frame) do
    IO.write([IO.ANSI.home(), IO.ANSI.clear(), frame, "\n"])
  end

  defp enter_terminal do
    _ = tty_stty("raw -echo min 0 time 0")
    IO.write(["\e[?1049h", "\e[?25l"])
  rescue
    _ -> :ok
  end

  defp restore_terminal(old_stty) do
    IO.write(["\e[?25h", "\e[?1049l"])

    if is_binary(old_stty) and old_stty != "" do
      _ = tty_stty(old_stty)
    else
      _ = tty_stty("sane")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp capture_stty do
    case tty_stty("-g") do
      {mode, 0} -> String.trim(mode)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp tty_stty(args) do
    System.cmd("sh", ["-c", "stty #{args} < /dev/tty"], stderr_to_stdout: true)
  end

  defp wait_for_key(interval_ms, false) do
    Process.sleep(interval_ms)
    :tick
  end

  defp wait_for_key(interval_ms, true) do
    deadline = System.monotonic_time(:millisecond) + interval_ms
    poll_key(deadline)
  end

  defp poll_key(deadline) do
    case read_key() do
      :none ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          :tick
        else
          Process.sleep(min(50, deadline - now))
          poll_key(deadline)
        end

      key ->
        key
    end
  end

  defp read_key do
    case IO.getn(:stdio, "", 1) do
      "q" -> :quit
      <<3>> -> :quit
      "r" -> :refresh
      "?" -> :help
      "k" -> :up
      "j" -> :down
      "\e" -> escape_key()
      "" -> :none
      :eof -> :none
      {:error, _reason} -> :none
      _ -> :none
    end
  end

  defp escape_key do
    case IO.getn(:stdio, "", 2) do
      "[A" -> :up
      "[B" -> :down
      _ -> :none
    end
  end
end
