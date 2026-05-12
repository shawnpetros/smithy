defmodule SymphonyElixir.Runtime.ClaudeCode.AppServer do
  @moduledoc """
  Port-management adapter for the Claude Code CLI runtime. Implements the
  `SymphonyElixir.Runtime` behaviour.

  Claude Code is single-shot per turn: the CLI is spawned with `--print`,
  emits a JSONL stream on stdout, and exits when the result event fires.
  Multi-turn continuity is via `--continue <session_id>` on subsequent
  invocations rather than a long-lived port (in contrast to Codex AppServer
  which keeps one port across many turns).

  ## Lifecycle

      {:ok, session} = AppServer.start_session(workspace, tier: :sonnet)
      {:ok, summary} = AppServer.run_turn(session, prompt, issue, on_message: cb)
      :ok = AppServer.stop_session(session)

  `start_session/2` only validates the workspace and captures the session
  config. The port opens inside `run_turn/4` and closes when the result event
  arrives (or on timeout / port exit).

  ## Events

  Events are normalized by `SymphonyElixir.Runtime.ClaudeCode.EventParser` and
  passed through the `:on_message` callback in `run_turn` opts. Default is
  `Logger.info/1` at info level. Same convention as `Codex.AppServer`.

  ## Partial-line buffering

  Ports deliver JSONL as raw chunks; a single message may straddle a newline,
  e.g. `{"type":"a` then `ssistant"}\\n{"type":"resu`. The receive loop buffers
  in an accumulator string until a `\\n` arrives, splits the accumulator on
  newlines, parses every completed line, and keeps the trailing partial for
  the next iteration.
  """

  @behaviour SymphonyElixir.Runtime

  require Logger
  alias SymphonyElixir.Runtime.ClaudeCode.{Argv, EventParser}

  @default_turn_timeout_ms 600_000

  @type session :: %{
          port: port() | nil,
          workspace: Path.t(),
          session_id: String.t() | nil,
          persona_path: String.t() | nil,
          tier: atom() | String.t(),
          mcp_config_path: String.t() | nil,
          disallowed_tools: [String.t()],
          claude_bin: String.t(),
          accumulator: String.t()
        }

  @type summary :: %{
          session_id: String.t() | nil,
          total_cost_usd: number(),
          num_turns: non_neg_integer(),
          is_error: boolean(),
          result_text: String.t() | nil,
          errors: [String.t()],
          final_event_count: non_neg_integer()
        }

  # ----- behaviour callbacks -----

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    with :ok <- validate_workspace(workspace) do
      session = %{
        port: nil,
        workspace: Path.expand(workspace),
        session_id: Keyword.get(opts, :session_id),
        persona_path: Keyword.get(opts, :persona_path),
        tier: Keyword.get(opts, :tier, :sonnet),
        mcp_config_path: Keyword.get(opts, :mcp_config_path),
        disallowed_tools: Keyword.get(opts, :disallowed_tools, Argv.default_disallowed_tools()),
        claude_bin: resolve_claude_bin(Keyword.get(opts, :claude_bin)),
        accumulator: ""
      }

      {:ok, session}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, summary()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ [])
      when is_map(session) and is_binary(prompt) and is_list(opts) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    timeout_ms = Keyword.get(opts, :turn_timeout_ms, default_turn_timeout_ms())
    max_budget = Keyword.get(opts, :max_budget_usd)

    argv = build_argv(session, max_budget)

    case open_port(session, argv, prompt) do
      {:ok, port} ->
        Logger.info(
          "ClaudeCode session start workspace=#{session.workspace} " <>
            "issue=#{inspect(Map.get(issue, :identifier))} tier=#{inspect(session.tier)} " <>
            "session_id=#{inspect(session.session_id)}"
        )

        session = %{session | port: port, accumulator: ""}

        case receive_loop(session, on_message, timeout_ms, nil, 0) do
          {:ok, %{result: result, session_id: sid, event_count: count}} ->
            summary = %{
              session_id: sid || session.session_id,
              total_cost_usd: result.total_cost_usd,
              num_turns: result.num_turns,
              is_error: result.is_error,
              result_text: result.result_text,
              errors: result.errors,
              final_event_count: count
            }

            close_port(port)
            {:ok, summary}

          {:error, reason} ->
            close_port(port)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: nil}), do: :ok

  def stop_session(%{port: port}) when is_port(port) do
    close_port(port)
    :ok
  end

  def stop_session(_), do: :ok

  # ----- internal: workspace validation -----

  defp validate_workspace(workspace) do
    expanded = Path.expand(workspace)

    cond do
      not File.exists?(expanded) -> {:error, {:invalid_workspace, :missing, expanded}}
      not File.dir?(expanded) -> {:error, {:invalid_workspace, :not_a_directory, expanded}}
      true -> :ok
    end
  end

  # ----- internal: binary resolution -----

  defp resolve_claude_bin(nil) do
    case :os.find_executable(~c"claude") do
      false -> "claude"
      path when is_list(path) -> List.to_string(path)
    end
  end

  defp resolve_claude_bin(path) when is_binary(path), do: path

  # ----- internal: argv construction -----

  defp build_argv(session, max_budget) do
    base_opts = [
      tier: session.tier,
      disallowed_tools: session.disallowed_tools
    ]

    base_opts
    |> maybe_kw(:session_id, session.session_id)
    |> maybe_kw(:max_budget_usd, max_budget)
    |> maybe_kw(:mcp_config, session.mcp_config_path)
    |> maybe_strict_mcp(session.mcp_config_path)
    |> then(&Argv.build(session.claude_bin, &1))
  end

  defp maybe_kw(opts, _key, nil), do: opts
  defp maybe_kw(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_strict_mcp(opts, nil), do: opts
  defp maybe_strict_mcp(opts, _path), do: Keyword.put(opts, :strict_mcp_config, true)

  # ----- internal: port lifecycle -----

  defp open_port(session, argv, prompt) do
    bin = session.claude_bin
    full_args = argv ++ [prompt]

    case File.regular?(bin) and File.exists?(bin) do
      true ->
        try do
          port =
            Port.open(
              {:spawn_executable, String.to_charlist(bin)},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                :hide,
                args: Enum.map(full_args, &String.to_charlist/1),
                cd: String.to_charlist(session.workspace)
              ]
            )

          {:ok, port}
        rescue
          e -> {:error, {:port_open_failed, Exception.message(e)}}
        end

      false ->
        # Defer to spawn anyway so the error surfaces uniformly; if `bin` was
        # the literal "claude" fallback, Port.open will raise.
        try do
          port =
            Port.open(
              {:spawn_executable, String.to_charlist(bin)},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                :hide,
                args: Enum.map(full_args, &String.to_charlist/1),
                cd: String.to_charlist(session.workspace)
              ]
            )

          {:ok, port}
        rescue
          e -> {:error, {:port_open_failed, Exception.message(e)}}
        end
    end
  end

  defp close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        :ok
    end
  end

  @doc false
  @spec default_turn_timeout_ms() :: pos_integer()
  def default_turn_timeout_ms do
    case System.get_env("SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS") do
      value when is_binary(value) ->
        parse_positive_integer(value, @default_turn_timeout_ms)

      _ ->
        @default_turn_timeout_ms
    end
  end

  defp parse_positive_integer(value, fallback) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  # ----- internal: receive loop -----

  # State carried through the loop:
  #   session.accumulator : partial-line buffer
  #   captured_session_id : captured from :init for next-turn continuity
  #   event_count         : how many parsed events emitted
  defp receive_loop(session, on_message, timeout_ms, captured_session_id, event_count) do
    port = session.port

    receive do
      {^port, {:data, chunk}} when is_binary(chunk) ->
        process_chunk(session, chunk, on_message, timeout_ms, captured_session_id, event_count)

      {^port, {:exit_status, status}} ->
        # If we got here, the port closed before emitting a :result event.
        # Drain whatever's left in the accumulator (rare; result usually lands
        # before the close), then surface as a port-exit error.
        _ = drain_accumulator(session, on_message)
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        kill_port(port)
        {:error, :timeout}
    end
  end

  # Public-ish helper so tests can simulate the chunk path without a real port.
  # Not part of the @callback contract; mark with @doc false to hide from docs.
  @doc false
  @spec process_chunk(session(), String.t(), (term() -> term()), pos_integer(), String.t() | nil, non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def process_chunk(session, chunk, on_message, timeout_ms, captured_session_id, event_count) do
    {complete_lines, remainder} = split_lines(session.accumulator <> chunk)

    case process_lines(complete_lines, on_message, captured_session_id, event_count) do
      {:result, result, sid, count} ->
        {:ok, %{result: result, session_id: sid, event_count: count}}

      {:continue, sid, count} ->
        session = %{session | accumulator: remainder}
        receive_loop(session, on_message, timeout_ms, sid, count)
    end
  end

  # Split a buffer on newline. The last fragment is returned as remainder
  # unless the buffer ended on a newline (in which case remainder is "").
  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")

    case parts do
      [] ->
        {[], ""}

      _ ->
        {complete, [trailing]} = Enum.split(parts, -1)

        if String.ends_with?(buffer, "\n") do
          {complete ++ [trailing], ""}
        else
          {complete, trailing}
        end
    end
  end

  # Walk completed lines in order. Emit each parsed event through on_message.
  # Stop early on :result event (the terminal signal from claude).
  defp process_lines([], _on_message, captured_session_id, count) do
    {:continue, captured_session_id, count}
  end

  defp process_lines([line | rest], on_message, captured_session_id, count) do
    case EventParser.parse_line(line) do
      nil ->
        process_lines(rest, on_message, captured_session_id, count)

      {:malformed, raw} ->
        Logger.debug("ClaudeCode malformed line: #{inspect(String.slice(raw, 0, 200))}")
        emit(on_message, {:malformed, raw})
        process_lines(rest, on_message, captured_session_id, count + 1)

      {:init, init} = event ->
        emit(on_message, event)
        new_sid = init.session_id || captured_session_id
        process_lines(rest, on_message, new_sid, count + 1)

      {:result, result} = event ->
        emit(on_message, event)
        {:result, result, captured_session_id, count + 1}

      event ->
        emit(on_message, event)
        process_lines(rest, on_message, captured_session_id, count + 1)
    end
  end

  # Flush any remaining partial-line in the accumulator on abnormal port exit.
  # Best effort: a partial line may not parse, that's fine.
  defp drain_accumulator(%{accumulator: ""}, _on_message), do: :ok

  defp drain_accumulator(%{accumulator: acc}, on_message) when is_binary(acc) do
    case EventParser.parse_line(acc) do
      nil -> :ok
      event -> emit(on_message, event)
    end

    :ok
  end

  defp emit(on_message, event) when is_function(on_message, 1) do
    on_message.(event)
  end

  defp emit(_on_message, _event), do: :ok

  defp default_on_message(event) do
    Logger.info("ClaudeCode event: #{inspect(event)}")
    :ok
  end

  defp kill_port(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} ->
        # Best-effort SIGKILL; ignore failures (process may already be gone).
        _ = System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
        close_port(port)

      _ ->
        close_port(port)
    end
  end

  defp kill_port(_), do: :ok
end
