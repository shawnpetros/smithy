defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace.

  Mode dispatch lives here (sub-pass B):

    * `:builder`  -> existing Codex flow (runtime selection from
      `agent_config.runtime` is sub-pass C scope; v1 always uses Codex).
    * `:reviewer` -> `SymphonyElixir.Modes.Reviewer.run/4` then transition
      Linear state based on the outcome (PASS -> `Human Review` or `Merging`,
      FAIL -> `Rework`, BLOCKED -> stays in `Adversarial Review` with the
      `harness-blocked` label).
    * `:triager`  -> `SymphonyElixir.Modes.Triager.run/4` then transition
      Linear state (PROCEED -> `In Progress`, FLAG -> `Backlog` with
      `needs-spec` + `-agent-ready`, BLOCKED -> stays in `Todo` with
      `harness-blocked`).

  State transition writes are best-effort inside this short-lived runner:
  `Tracker.update_issue_state/2` errors are logged but not retried here. Linear
  remains the source of truth, and the next orchestrator poll/reconcile decides
  whether the unchanged ticket state should be dispatched again or surfaced for
  operator recovery.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, Modes, PromptBuilder, Telemetry, Tracker, Workpad, Workspace}
  alias SymphonyElixir.Handoff.Review

  @type worker_host :: String.t() | nil

  @run_id_pdict_key :smithy_run_id
  @telemetry_mod_pdict_key :smithy_telemetry_mod
  # PER-157: process-dict accumulator for per-turn token usage + cost. Reset
  # at the start of each turn iteration; read at :turn_end emit time. The
  # on_message callback wrapper captures usage from claude/codex events
  # directly into this key, in the same process that does the emit.
  @turn_usage_pdict_key :smithy_turn_usage

  @empty_turn_usage %{
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_creation_tokens: 0,
    cost_usd: 0.0
  }

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    mode = Keyword.get(opts, :mode, :builder)
    agent_config = Keyword.get(opts, :agent_config)
    telemetry_mod = Keyword.get(opts, :telemetry_mod, Telemetry)

    run_id = generate_run_id()
    run_started_at = System.monotonic_time(:millisecond)

    # Threaded via the process dictionary so deep helpers (per-turn, state
    # transitions) can correlate without changing internal signatures. The
    # process is short-lived (one task per ticket) so cross-contamination is
    # contained.
    Process.put(@run_id_pdict_key, run_id)
    Process.put(@telemetry_mod_pdict_key, telemetry_mod)

    Logger.info("Starting agent run for #{issue_context(issue)} mode=#{mode} worker_host=#{worker_host_for_log(worker_host)}")

    safe_emit(telemetry_mod, :session_start,
      ticket: issue.identifier,
      mode: mode,
      runtime: agent_config && agent_config.runtime,
      persona: agent_config && agent_config.persona,
      tier: agent_config && agent_config.tier,
      run_id: run_id
    )

    try do
      result =
        case mode do
          :builder ->
            run_builder_mode(issue, codex_update_recipient, opts, worker_host)

          :reviewer ->
            run_reviewer_mode(issue, agent_config, opts, worker_host)

          :triager ->
            run_triager_mode(issue, agent_config, opts, worker_host)
        end

      safe_emit(telemetry_mod, :session_end,
        ticket: issue.identifier,
        mode: mode,
        duration_ms: System.monotonic_time(:millisecond) - run_started_at,
        outcome: :success,
        run_id: run_id
      )

      result
    rescue
      exception ->
        safe_emit(telemetry_mod, :session_end,
          ticket: issue.identifier,
          mode: mode,
          duration_ms: System.monotonic_time(:millisecond) - run_started_at,
          outcome: :error,
          run_id: run_id,
          error: Exception.message(exception)
        )

        reraise exception, __STACKTRACE__
    after
      Process.delete(@run_id_pdict_key)
      Process.delete(@telemetry_mod_pdict_key)
    end
  end

  defp run_builder_mode(issue, codex_update_recipient, opts, worker_host) do
    agent_config = Keyword.get(opts, :agent_config)
    runtime = (agent_config && agent_config.runtime) || :codex

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host, runtime, agent_config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  # --- reviewer mode -------------------------------------------------------

  defp run_reviewer_mode(issue, agent_config, opts, worker_host) do
    reviewer_mod = Keyword.get(opts, :reviewer_mod, Modes.Reviewer)
    mode_opts = mode_opts_from_runner_opts(opts, worker_host)
    run_id = current_run_id()
    runtime = agent_config && agent_config.runtime

    safe_emit_pdict(:turn_start,
      ticket: issue.identifier,
      mode: :reviewer,
      runtime: runtime,
      run_id: run_id
    )

    turn_started_at = System.monotonic_time(:millisecond)

    dispatch =
      with {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host),
           {:ok, outcome} <- reviewer_mod.run(issue, workspace, agent_config, mode_opts) do
        {:dispatched, outcome}
      end

    {turn_outcome, ok_return} =
      case dispatch do
        {:dispatched, outcome} ->
          {reviewer_turn_outcome(outcome), fn -> handle_reviewer_outcome(issue, outcome, opts) end}

        {:error, reason} ->
          Logger.error("Reviewer mode failed for #{issue_context(issue)}: #{inspect(reason)}")
          {:error, fn -> apply_harness_blocked(issue, "reviewer error: #{inspect(reason)}", opts) end}
      end

    safe_emit_pdict(:turn_end,
      ticket: issue.identifier,
      mode: :reviewer,
      runtime: runtime,
      duration_ms: System.monotonic_time(:millisecond) - turn_started_at,
      outcome: turn_outcome,
      run_id: run_id
    )

    ok_return.()
    :ok
  end

  defp reviewer_turn_outcome({:pass, _}), do: :success
  defp reviewer_turn_outcome({:fail, _}), do: :success
  defp reviewer_turn_outcome({:blocked, _}), do: :error
  defp reviewer_turn_outcome(_), do: :error

  defp handle_reviewer_outcome(issue, {:pass, review}, opts) do
    workpad_append(issue, :adversarial_review, format_review_for_workpad(review, "PASS"), opts)
    next_state = if has_label?(issue, "auto-merge"), do: "Merging", else: "Human Review"
    update_issue_state(issue, next_state, opts)
  end

  defp handle_reviewer_outcome(issue, {:fail, review}, opts) do
    workpad_append(issue, :adversarial_review, format_review_for_workpad(review, "FAIL"), opts)
    if hard_reset?(review), do: add_label(issue, "smithy:hard-reset", opts)
    update_issue_state(issue, "Rework", opts)
  end

  defp handle_reviewer_outcome(issue, {:blocked, reason}, opts) do
    apply_harness_blocked(issue, reason, opts)
  end

  defp hard_reset?(%{findings: findings}) do
    Enum.any?(List.wrap(findings), fn f -> f.grade == :rebuild_from_scratch end)
  end

  defp hard_reset?(_), do: false

  # --- triager mode --------------------------------------------------------

  defp run_triager_mode(issue, agent_config, opts, worker_host) do
    triager_mod = Keyword.get(opts, :triager_mod, Modes.Triager)
    mode_opts = mode_opts_from_runner_opts(opts, worker_host)
    run_id = current_run_id()
    runtime = agent_config && agent_config.runtime

    safe_emit_pdict(:turn_start,
      ticket: issue.identifier,
      mode: :triager,
      runtime: runtime,
      run_id: run_id
    )

    turn_started_at = System.monotonic_time(:millisecond)

    dispatch =
      with {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host),
           {:ok, outcome} <- triager_mod.run(issue, workspace, agent_config, mode_opts) do
        {:dispatched, outcome}
      end

    {turn_outcome, ok_return} =
      case dispatch do
        {:dispatched, outcome} ->
          {triager_turn_outcome(outcome), fn -> handle_triager_outcome(issue, outcome, opts) end}

        {:error, reason} ->
          Logger.error("Triager mode failed for #{issue_context(issue)}: #{inspect(reason)}")
          {:error, fn -> apply_harness_blocked(issue, "triager error: #{inspect(reason)}", opts) end}
      end

    safe_emit_pdict(:turn_end,
      ticket: issue.identifier,
      mode: :triager,
      runtime: runtime,
      duration_ms: System.monotonic_time(:millisecond) - turn_started_at,
      outcome: turn_outcome,
      run_id: run_id
    )

    ok_return.()
    :ok
  end

  defp triager_turn_outcome({:proceed, _}), do: :success
  defp triager_turn_outcome({:flag, _}), do: :success
  defp triager_turn_outcome({:blocked, _}), do: :error
  defp triager_turn_outcome(_), do: :error

  defp handle_triager_outcome(issue, {:proceed, _triage}, opts) do
    # Builder will be dispatched on the next polling cycle.
    update_issue_state(issue, "In Progress", opts)
  end

  defp handle_triager_outcome(issue, {:flag, triage}, opts) do
    workpad_append(issue, :notes, "Triage flagged:\n\n" <> (triage.gap_comment || ""), opts)
    add_label(issue, "needs-spec", opts)
    remove_label(issue, "agent-ready", opts)
    update_issue_state(issue, "Backlog", opts)
  end

  defp handle_triager_outcome(issue, {:blocked, reason}, opts) do
    apply_harness_blocked(issue, reason, opts)
  end

  # --- shared mode helpers -------------------------------------------------

  defp mode_opts_from_runner_opts(opts, worker_host) do
    opts
    |> Keyword.take([:adapter, :persona_loader, :project_dir, :mcp_config_path, :on_message, :diff_fetcher, :review_reader, :triage_reader])
    |> Keyword.put_new(:worker_host, worker_host)
  end

  defp workpad_append(issue, section, content, opts) do
    workpad_mod = Keyword.get(opts, :workpad_mod, Workpad)

    case workpad_mod.append_section(issue.id, section, content, []) do
      {:ok, _comment_id} ->
        :ok

      {:error, reason} ->
        Logger.warning("Workpad append failed for #{issue.identifier}: #{inspect(reason)}")
        :ok
    end
  end

  defp update_issue_state(%Issue{id: issue_id, identifier: identifier, state: from_state}, state_name, opts) do
    tracker_mod = Keyword.get(opts, :tracker_mod, Tracker)

    case tracker_mod.update_issue_state(issue_id, state_name) do
      :ok ->
        safe_emit_pdict(:state_transition,
          ticket: identifier,
          from_state: from_state,
          to_state: state_name,
          run_id: current_run_id()
        )

        :ok

      {:error, reason} ->
        Logger.warning("State transition to #{state_name} failed for #{identifier}: #{inspect(reason)}")
        :ok
    end
  end

  defp apply_harness_blocked(issue, reason, opts) do
    add_label(issue, "harness-blocked", opts)
    workpad_append(issue, :notes, "Harness BLOCKED: " <> to_string(reason), opts)
  end

  defp format_review_for_workpad(%Review{} = review, status_label) do
    do_format_review_for_workpad(review.findings, review.notes, status_label)
  end

  defp format_review_for_workpad(%{findings: findings} = review, status_label) do
    do_format_review_for_workpad(findings, Map.get(review, :notes), status_label)
  end

  defp do_format_review_for_workpad(findings, notes, status_label) do
    findings_block =
      findings
      |> List.wrap()
      |> Enum.map_join("\n", fn
        %{finding: f, grade: g} -> "- [#{g}] #{f}"
        other -> "- #{inspect(other)}"
      end)

    notes_block =
      case notes do
        nil -> ""
        "" -> ""
        text when is_binary(text) -> "\n\n" <> text
        other -> "\n\n" <> inspect(other)
      end

    "**#{status_label}**\n\n#{findings_block}#{notes_block}"
  end

  defp has_label?(%Issue{labels: labels}, target) when is_list(labels) do
    Enum.any?(labels, fn
      %{name: name} -> name == target
      name when is_binary(name) -> name == target
      _ -> false
    end)
  end

  defp has_label?(_, _), do: false

  defp add_label(issue, label_name, opts) do
    tracker_mod = Keyword.get(opts, :tracker_mod, Tracker)

    try do
      case tracker_mod.add_label(issue, label_name) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Label add #{label_name} failed for #{issue.identifier}: #{inspect(reason)}")
          :ok
      end
    rescue
      UndefinedFunctionError ->
        Logger.warning("Tracker.add_label/2 not implemented; skipping label #{label_name} for #{issue.identifier}")
        :ok
    end
  end

  defp remove_label(issue, label_name, opts) do
    tracker_mod = Keyword.get(opts, :tracker_mod, Tracker)

    try do
      case tracker_mod.remove_label(issue, label_name) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Label remove #{label_name} failed for #{issue.identifier}: #{inspect(reason)}")
          :ok
      end
    rescue
      UndefinedFunctionError ->
        Logger.warning("Tracker.remove_label/2 not implemented; skipping label #{label_name} for #{issue.identifier}")
        :ok
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host, runtime, agent_config) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} runtime=#{runtime} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            case runtime do
              :claude_code ->
                run_claude_turns(workspace, issue, codex_update_recipient, opts, worker_host, agent_config)

              _ ->
                run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      capture_turn_usage(message)
      send_codex_update(recipient, issue, message)
    end
  end

  # PER-157: harvest token usage + cost from runtime events into the process
  # dict so the next :turn_end emit can include them. Called on every event
  # from claude/codex AppServer via the wrapped on_message callback. Same
  # process runs the emit, so process dict is the right scope.
  defp capture_turn_usage({:assistant_message, %{usage: usage}}) when is_map(usage) do
    current = Process.get(@turn_usage_pdict_key, @empty_turn_usage)

    Process.put(@turn_usage_pdict_key, %{
      input_tokens: current.input_tokens + Map.get(usage, "input_tokens", 0),
      output_tokens: current.output_tokens + Map.get(usage, "output_tokens", 0),
      cache_read_tokens:
        current.cache_read_tokens + Map.get(usage, "cache_read_input_tokens", 0),
      cache_creation_tokens:
        current.cache_creation_tokens + Map.get(usage, "cache_creation_input_tokens", 0),
      cost_usd: current.cost_usd
    })
  end

  defp capture_turn_usage({:result, %{total_cost_usd: cost}}) when is_number(cost) do
    current = Process.get(@turn_usage_pdict_key, @empty_turn_usage)
    Process.put(@turn_usage_pdict_key, %{current | cost_usd: current.cost_usd + cost})
  end

  defp capture_turn_usage(_event), do: :ok

  defp reset_turn_usage do
    Process.put(@turn_usage_pdict_key, @empty_turn_usage)
  end

  defp read_turn_usage do
    Process.get(@turn_usage_pdict_key, @empty_turn_usage)
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    run_id = current_run_id()

    safe_emit_pdict(:turn_start,
      ticket: issue.identifier,
      mode: :builder,
      runtime: :codex,
      turn_number: turn_number,
      run_id: run_id
    )

    turn_started_at = System.monotonic_time(:millisecond)

    turn_result =
      AppServer.run_turn(
        app_session,
        prompt,
        issue,
        on_message: codex_message_handler(codex_update_recipient, issue)
      )

    duration_ms = System.monotonic_time(:millisecond) - turn_started_at

    case turn_result do
      {:ok, turn_session} ->
        # Token counts: AppServer reports usage via on_message callbacks and
        # does not surface them in the run_turn return value yet. Emit nils
        # for now; the AppServer plumbing can be extended in a follow-up.
        safe_emit_pdict(:turn_end,
          ticket: issue.identifier,
          mode: :builder,
          runtime: :codex,
          turn_number: turn_number,
          duration_ms: duration_ms,
          input_tokens: turn_session[:input_tokens],
          output_tokens: turn_session[:output_tokens],
          outcome: :success,
          run_id: run_id,
          session_id: turn_session[:session_id]
        )

        :ok

      {:error, reason} ->
        safe_emit_pdict(:turn_end,
          ticket: issue.identifier,
          mode: :builder,
          runtime: :codex,
          turn_number: turn_number,
          duration_ms: duration_ms,
          outcome: :error,
          run_id: run_id,
          error: inspect(reason)
        )
    end

    with {:ok, turn_session} <- turn_result do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher, :builder) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Claude Code builder turns: mirrors run_codex_turns but uses the Claude Code
  # AppServer adapter. Multi-turn continuity via --continue <session_id> threaded
  # across run_turn calls. Each turn is one `claude --print` invocation; the
  # adapter handles the session bookkeeping.
  defp run_claude_turns(workspace, issue, recipient, opts, worker_host, agent_config) do
    alias SymphonyElixir.Runtime.ClaudeCode.AppServer, as: ClaudeAppServer

    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    tier = (agent_config && agent_config.tier) || "sonnet"

    session_opts = [
      worker_host: worker_host,
      tier: claude_tier_atom(tier),
      mode: :builder
    ]

    with {:ok, session} <- ClaudeAppServer.start_session(workspace, session_opts) do
      try do
        do_run_claude_turns(session, workspace, issue, recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        ClaudeAppServer.stop_session(session)
      end
    end
  end

  defp do_run_claude_turns(session, workspace, issue, recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    alias SymphonyElixir.Runtime.ClaudeCode.AppServer, as: ClaudeAppServer

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    run_id = current_run_id()

    safe_emit_pdict(:turn_start,
      ticket: issue.identifier,
      mode: :builder,
      runtime: :claude_code,
      turn_number: turn_number,
      run_id: run_id
    )

    reset_turn_usage()
    turn_started_at = System.monotonic_time(:millisecond)
    turn_result = ClaudeAppServer.run_turn(session, prompt, issue, on_message: codex_message_handler(recipient, issue))
    duration_ms = System.monotonic_time(:millisecond) - turn_started_at

    case turn_result do
      {:ok, summary} ->
        usage = read_turn_usage()

        safe_emit_pdict(:turn_end,
          ticket: issue.identifier,
          mode: :builder,
          runtime: :claude_code,
          turn_number: turn_number,
          duration_ms: duration_ms,
          input_tokens: usage.input_tokens,
          output_tokens: usage.output_tokens,
          cache_read_tokens: usage.cache_read_tokens,
          cache_creation_tokens: usage.cache_creation_tokens,
          cost_usd: usage.cost_usd,
          outcome: :success,
          run_id: run_id
        )

        Logger.info("Completed Claude builder turn for #{issue_context(issue)} session_id=#{summary[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher, :builder) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            do_run_claude_turns(session, workspace, refreshed_issue, recipient, opts, issue_state_fetcher, turn_number + 1, max_turns)

          {:continue, _} ->
            Logger.info("Reached agent.max_turns for #{issue_context(issue)} (claude) with issue still active; returning control to orchestrator")
            :ok

          {:done, _} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        safe_emit_pdict(:turn_end,
          ticket: issue.identifier,
          mode: :builder,
          runtime: :claude_code,
          turn_number: turn_number,
          duration_ms: duration_ms,
          outcome: :error,
          error: inspect(reason),
          run_id: run_id
        )

        {:error, reason}
    end
  end

  defp claude_tier_atom("opus"), do: :opus
  defp claude_tier_atom("sonnet"), do: :sonnet
  defp claude_tier_atom("haiku"), do: :haiku
  defp claude_tier_atom(:opus), do: :opus
  defp claude_tier_atom(:sonnet), do: :sonnet
  defp claude_tier_atom(:haiku), do: :haiku
  defp claude_tier_atom(_), do: :sonnet

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  # Decide whether the current agent loop should continue with another turn.
  #
  # Two checks gate continuation:
  #
  # 1. Is the issue still in an active (non-terminal) state? Terminal states
  #    (Done, Closed, Cancelled, etc.) always return `:done`.
  # 2. Does the current state still map to the agent's mode? An agent dispatched
  #    as `:builder` should NOT keep looping after the issue transitions to
  #    `Adversarial Review`. The agent's work caused that transition; the next
  #    dispatch should be `:reviewer`. Returning `:done` here yields control
  #    back to the orchestrator, which re-evaluates mode on its next poll.
  #
  # Without check #2, builder loops empty turns ("I shouldn't act on
  # Adversarial Review") until max_turns, wasting input tokens (PER-192).
  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, mode)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        cond do
          not active_issue_state?(refreshed_issue.state) ->
            {:done, refreshed_issue}

          not state_matches_mode?(refreshed_issue.state, mode) ->
            Logger.info(
              "Issue #{refreshed_issue.identifier} state=#{refreshed_issue.state} " <>
                "no longer matches agent mode=#{mode}; returning to orchestrator for re-dispatch"
            )

            {:done, refreshed_issue}

          true ->
            {:continue, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _mode), do: {:done, issue}

  # Active-state predicate is config-driven (tracker.active_states in WORKFLOW.md).
  # Mode-state alignment is hardcoded here because it expresses the state machine
  # contract, not operator preference: a builder's territory is Todo/In Progress/
  # Rework/Merging, a reviewer's is Adversarial Review, a triager's is Todo.
  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp state_matches_mode?(state, mode) when is_binary(state) and is_atom(mode) do
    normalized = normalize_issue_state(state)

    case mode do
      :builder -> normalized in ["todo", "in progress", "rework", "merging"]
      :reviewer -> normalized == "adversarial review"
      :triager -> normalized == "todo"
      _ -> true
    end
  end

  defp state_matches_mode?(_state, _mode), do: true

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  # --- telemetry helpers ---------------------------------------------------

  defp generate_run_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp current_run_id, do: Process.get(@run_id_pdict_key)

  defp current_telemetry_mod, do: Process.get(@telemetry_mod_pdict_key, Telemetry)

  # Telemetry.emit is already fire-and-forget, but a stubbed telemetry_mod
  # could raise. Catch everything so a broken emit never crashes the run.
  defp safe_emit(telemetry_mod, kind, opts) do
    telemetry_mod.emit(kind, opts)
    :ok
  rescue
    exception ->
      Logger.warning("Telemetry emit failed kind=#{inspect(kind)} reason=#{Exception.message(exception)}")

      :ok
  end

  defp safe_emit_pdict(kind, opts) do
    safe_emit(current_telemetry_mod(), kind, opts)
  end
end
