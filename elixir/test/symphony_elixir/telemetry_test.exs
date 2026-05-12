defmodule SymphonyElixir.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Telemetry
  alias SymphonyElixir.Telemetry.{Event, Store}

  setup do
    # The app supervisor starts a Telemetry process at boot. Terminate it
    # via the supervisor so it doesn't auto-restart underneath us, then
    # restart it after each test.
    sup = SymphonyElixir.Supervisor
    _ = Supervisor.terminate_child(sup, SymphonyElixir.Telemetry)

    unique = :erlang.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "smithy-telemetry-#{unique}")
    File.rm_rf!(dir)

    on_exit(fn ->
      if pid = Process.whereis(SymphonyElixir.Telemetry) do
        Process.unregister(SymphonyElixir.Telemetry)
        Process.exit(pid, :shutdown)
        wait_until_gone(pid)
      end

      _ = Supervisor.restart_child(sup, SymphonyElixir.Telemetry)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  describe "start_link/1 + emit/2" do
    test "emit/2 returns :ok immediately", %{dir: dir} do
      {:ok, _pid} = Telemetry.start_link(telemetry_dir: dir)
      assert :ok = Telemetry.emit(:turn_start, ticket: "PER-1", repo_slug: "smithy")
    end

    test "emit/2 actually persists when the GenServer is running", %{dir: dir} do
      {:ok, pid} = Telemetry.start_link(telemetry_dir: dir)

      :ok =
        Telemetry.emit(:turn_end,
          ticket: "PER-1",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:00:00Z],
          duration_ms: 4127,
          outcome: :success,
          input_tokens: 6,
          output_tokens: 25,
          cost_usd: 0.195
        )

      # Drain the mailbox.
      _ = :sys.get_state(pid)

      events = Store.read_stream(telemetry_dir: dir) |> Enum.to_list()
      assert length(events) == 1
      [ev] = events
      assert ev.ticket == "PER-1"
      assert ev.duration_ms == 4127
      assert ev.outcome == :success
    end

    test "emit/2 does not crash when the GenServer is down", %{dir: _dir} do
      refute Process.whereis(SymphonyElixir.Telemetry)

      log =
        capture_log(fn ->
          assert :ok = Telemetry.emit(:turn_end, ticket: "PER-1")
        end)

      assert log =~ "Telemetry GenServer not running"
    end
  end

  describe "query/1" do
    test "returns a stream of events from disk", %{dir: dir} do
      {:ok, pid} = Telemetry.start_link(telemetry_dir: dir)

      for i <- 1..3 do
        Telemetry.emit(:turn_end,
          ticket: "PER-#{i}",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:00:00Z],
          duration_ms: i * 100,
          outcome: :success
        )
      end

      _ = :sys.get_state(pid)

      events = Telemetry.query(telemetry_dir: dir) |> Enum.to_list()
      assert length(events) == 3
    end
  end

  describe "stats/1" do
    test "computes median/p95/max correctly across a fixture set", %{dir: dir} do
      fixtures = [
        {100, :success, 0.1, :builder, :codex},
        {200, :success, 0.2, :builder, :codex},
        {300, :success, 0.3, :reviewer, :claude_code},
        {400, :timeout, 0.4, :reviewer, :claude_code},
        {500, :error, 0.5, :triager, :codex},
        {600, :success, 0.6, :builder, :codex},
        {700, :success, 0.7, :builder, :codex},
        {800, :success, 0.8, :reviewer, :claude_code},
        {900, :success, 0.9, :reviewer, :claude_code},
        {10_000, :success, 5.0, :builder, :codex}
      ]

      for {{dur, outcome, cost, mode, runtime}, i} <- Enum.with_index(fixtures, 1) do
        event =
          Event.build(:turn_end,
            ticket: "PER-#{i}",
            repo_slug: "smithy",
            occurred_at: ~U[2026-05-12 10:00:00Z],
            duration_ms: dur,
            outcome: outcome,
            cost_usd: cost,
            mode: mode,
            runtime: runtime,
            input_tokens: 100,
            output_tokens: 50
          )

        :ok = Store.write(event, telemetry_dir: dir)
      end

      result = Telemetry.stats(telemetry_dir: dir)

      assert result.tickets_total == 10
      assert result.tickets_by_outcome.success == 8
      assert result.tickets_by_outcome.timeout == 1
      assert result.tickets_by_outcome.error == 1

      assert result.wall_clock_ms.samples == 10
      assert result.wall_clock_ms.max == 10_000
      # median: index round(10 * 0.5) = 5 (sorted[5] = 600)
      assert result.wall_clock_ms.median == 600
      # p95: index round(10 * 0.95) = 10 -> clamped to 9 -> 10_000
      assert result.wall_clock_ms.p95 == 10_000

      assert result.tokens.input == 1_000
      assert result.tokens.output == 500
      assert result.tokens.total == 1_500

      assert result.cost_usd.total == 9.5
      # median cost: sorted[5] = 0.6
      assert result.cost_usd.median_per_ticket == 0.6
      assert result.cost_usd.max_per_ticket == 5.0

      assert result.runtime_split == %{codex: 6, claude_code: 4}
      assert result.mode_split == %{builder: 5, reviewer: 4, triager: 1}
    end

    test "handles empty result set without crashing", %{dir: dir} do
      result = Telemetry.stats(telemetry_dir: dir)

      assert result.tickets_total == 0
      assert result.wall_clock_ms == %{median: 0, p95: 0, max: 0, samples: 0}
      assert result.tokens == %{input: 0, output: 0, total: 0}
      assert result.cost_usd == %{total: 0.0, median_per_ticket: 0.0, max_per_ticket: 0.0}
      assert result.runtime_split == %{}
      assert result.mode_split == %{}
    end

    test "populates range when from/to provided", %{dir: dir} do
      result = Telemetry.stats(telemetry_dir: dir, from: ~D[2026-05-01], to: ~D[2026-05-31])
      assert %DateTime{} = result.range.from
      assert %DateTime{} = result.range.to
    end
  end

  defp wait_until_gone(pid, attempts \\ 50) do
    cond do
      not Process.alive?(pid) -> :ok
      attempts <= 0 -> :ok
      true ->
        Process.sleep(10)
        wait_until_gone(pid, attempts - 1)
    end
  end
end
