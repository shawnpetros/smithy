defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Starts a single agent session for a Linear issue.

  `AgentRunner` owns session-scoped telemetry and worker-host selection, then
  delegates mode-specific execution to `SymphonyElixir.Modes.Dispatch`.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, Modes.Dispatch, Telemetry}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    mode = Keyword.get(opts, :mode, :builder)
    agent_config = Keyword.get(opts, :agent_config)
    telemetry_mod = Keyword.get(opts, :telemetry_mod, Telemetry)
    run_id = generate_run_id()
    run_started_at = System.monotonic_time(:millisecond)
    dispatch_opts = opts |> Keyword.put(:telemetry_mod, telemetry_mod) |> Keyword.put(:run_id, run_id)

    Logger.info("Starting agent run for #{issue_context(issue)} mode=#{mode} worker_host=#{worker_host_for_log(worker_host)}")

    Telemetry.safe_emit(telemetry_mod, :session_start,
      ticket: issue.identifier,
      mode: mode,
      runtime: agent_config && agent_config.runtime,
      persona: agent_config && agent_config.persona,
      tier: agent_config && agent_config.tier,
      run_id: run_id
    )

    try do
      result = Dispatch.run(issue, codex_update_recipient, dispatch_opts, worker_host)

      Telemetry.safe_emit(telemetry_mod, :session_end,
        ticket: issue.identifier,
        mode: mode,
        duration_ms: System.monotonic_time(:millisecond) - run_started_at,
        outcome: :success,
        run_id: run_id
      )

      result
    rescue
      exception ->
        Telemetry.safe_emit(telemetry_mod, :session_end,
          ticket: issue.identifier,
          mode: mode,
          duration_ms: System.monotonic_time(:millisecond) - run_started_at,
          outcome: :error,
          run_id: run_id,
          error: Exception.message(exception)
        )

        reraise exception, __STACKTRACE__
    end
  end

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

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp generate_run_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
