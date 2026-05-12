defmodule SymphonyElixir.Modes.Dispatch do
  @moduledoc """
  Routes configured agent modes to their runners.

  The top-level runner owns session telemetry. This module owns the mode case,
  builder failure normalization, and the shared reviewer/triager turn boundary
  around workspace creation, mode execution, outcome routing, and turn
  telemetry.
  """

  require Logger

  alias SymphonyElixir.{Linear.Issue, Modes, Telemetry, Workspace}

  @type worker_host :: String.t() | nil

  @doc false
  @spec run(Issue.t(), pid() | nil, keyword(), worker_host()) :: :ok | no_return()
  def run(issue, codex_update_recipient, opts, worker_host) do
    case Keyword.get(opts, :mode, :builder) do
      :builder ->
        run_builder_mode(issue, codex_update_recipient, opts, worker_host)

      :reviewer ->
        Modes.Reviewer.run_mode(issue, Keyword.get(opts, :agent_config), opts, worker_host)

      :triager ->
        Modes.Triager.run_mode(issue, Keyword.get(opts, :agent_config), opts, worker_host)
    end
  end

  @doc false
  @spec run_outcome_mode(
          atom(),
          Issue.t(),
          term(),
          keyword(),
          worker_host(),
          module(),
          function(),
          function()
        ) :: :ok
  def run_outcome_mode(mode, issue, agent_config, opts, worker_host, mode_mod, outcome_handler, turn_outcome) do
    mode_opts = mode_opts_from_runner_opts(opts, worker_host)
    run_id = Keyword.get(opts, :run_id)
    runtime = agent_config && agent_config.runtime

    Telemetry.safe_emit(telemetry_mod(opts), :turn_start,
      ticket: issue.identifier,
      mode: mode,
      runtime: runtime,
      run_id: run_id
    )

    turn_started_at = System.monotonic_time(:millisecond)

    dispatch =
      with {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host),
           {:ok, outcome} <- mode_mod.run(issue, workspace, agent_config, mode_opts) do
        {:dispatched, outcome}
      end

    {telemetry_outcome, ok_return} =
      case dispatch do
        {:dispatched, outcome} ->
          {turn_outcome.(outcome), fn -> outcome_handler.(issue, outcome, opts) end}

        {:error, reason} ->
          Logger.error("#{mode_name_for_log(mode)} mode failed for #{issue_context(issue)}: #{inspect(reason)}")

          {:error,
           fn ->
             Modes.Outcomes.apply_harness_blocked(issue, "#{mode} error: #{inspect(reason)}", opts)
           end}
      end

    Telemetry.safe_emit(telemetry_mod(opts), :turn_end,
      ticket: issue.identifier,
      mode: mode,
      runtime: runtime,
      duration_ms: System.monotonic_time(:millisecond) - turn_started_at,
      outcome: telemetry_outcome,
      run_id: run_id
    )

    ok_return.()
    :ok
  end

  defp run_builder_mode(issue, codex_update_recipient, opts, worker_host) do
    case Modes.Builder.run(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp mode_opts_from_runner_opts(opts, worker_host) do
    opts
    |> Keyword.take([
      :adapter,
      :persona_loader,
      :project_dir,
      :mcp_config_path,
      :on_message,
      :diff_fetcher,
      :review_reader,
      :triage_reader
    ])
    |> Keyword.put_new(:worker_host, worker_host)
  end

  defp telemetry_mod(opts), do: Keyword.get(opts, :telemetry_mod, Telemetry)

  defp mode_name_for_log(:reviewer), do: "Reviewer"
  defp mode_name_for_log(:triager), do: "Triager"
  defp mode_name_for_log(mode), do: inspect(mode)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
