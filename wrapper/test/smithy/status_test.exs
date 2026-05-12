defmodule Smithy.StatusTest do
  use ExUnit.Case, async: true

  alias Smithy.{Config, RepoRegistry, Status, TUI}

  defp two_repo_config do
    {:ok, {c, _}} = RepoRegistry.add(Config.defaults(), "smithy", "/tmp/smithy")
    {:ok, {c, _}} = RepoRegistry.add(c, "substrate", "/tmp/substrate")
    c
  end

  defp sample_payload(running_n) do
    running =
      for i <- 1..running_n do
        %{
          "issue_identifier" => "MT-#{700 + i}",
          "state" => "Todo",
          "session_id" => "sess-#{i}",
          "started_at" =>
            DateTime.utc_now()
            |> DateTime.add(-90, :second)
            |> DateTime.truncate(:second)
            |> DateTime.to_iso8601(),
          "last_event" => "command output streaming",
          "tokens" => %{
            "input_tokens" => 100_000,
            "output_tokens" => 10_000,
            "total_tokens" => 110_000
          }
        }
      end

    %{
      "generated_at" => "2026-05-12T12:00:00Z",
      "counts" => %{"running" => running_n, "retrying" => 0, "max_agents" => 3},
      "running" => running,
      "retrying" => [],
      "codex_totals" => %{
        "input_tokens" => running_n * 100_000,
        "output_tokens" => running_n * 10_000,
        "total_tokens" => running_n * 110_000
      },
      "rate_limits" => %{}
    }
  end

  defp aggregate_fixture do
    %{
      repos: [
        %{
          slug: "smithy",
          port: 4001,
          url: "http://localhost:4001/api/v1/state",
          status: :online,
          error: nil,
          payload: %{
            "counts" => %{"running" => 1, "retrying" => 1, "max_agents" => 3},
            "running" => [
              %{
                "issue_identifier" => "PER-167",
                "state" => "In Progress",
                "pid" => 12_345,
                "runtime_seconds" => 125,
                "turn_count" => 3,
                "session_id" => "abcd1234567890",
                "last_message" => "command output streaming with a long enough summary",
                "tokens" => %{
                  "input_tokens" => 1_000,
                  "output_tokens" => 500,
                  "total_tokens" => 1_500
                }
              }
            ],
            "retrying" => [
              %{
                "issue_identifier" => "PER-199",
                "attempt" => 2,
                "due_at" => "2026-05-12T12:03:00Z",
                "error" => "rate limited"
              }
            ],
            "codex_totals" => %{
              "input_tokens" => 1_000,
              "output_tokens" => 500,
              "total_tokens" => 1_500
            }
          }
        },
        %{
          slug: "substrate",
          port: 4002,
          url: "http://localhost:4002/api/v1/state",
          status: :offline,
          error: :econnrefused,
          payload: nil
        }
      ],
      totals: %{
        registered: 2,
        active: 1,
        agents_running: 1,
        agents_capacity: 3,
        throughput_tps: 42,
        tokens_in: 1_000,
        tokens_out: 500,
        tokens_total: 1_500
      },
      generated_at: "2026-05-12T12:00:00Z"
    }
  end

  describe "collect/2" do
    test "assembles totals across online repos" do
      config = two_repo_config()

      client = fn url ->
        port = url |> String.split(":") |> Enum.at(2) |> String.split("/") |> hd()
        {n, _} = Integer.parse(port)
        running = if n == 4001, do: 3, else: 1
        {:ok, sample_payload(running)}
      end

      agg = Status.collect(config, client)

      assert agg.totals.registered == 2
      assert agg.totals.active == 2
      assert agg.totals.agents_running == 4
      assert agg.totals.tokens_total == 4 * 110_000
      assert length(agg.repos) == 2
      assert Enum.all?(agg.repos, &(&1.status == :online))
    end

    test "marks unreachable repos OFFLINE without crashing" do
      config = two_repo_config()

      client = fn url ->
        if String.contains?(url, "4001"),
          do: {:ok, sample_payload(2)},
          else: {:error, :econnrefused}
      end

      agg = Status.collect(config, client)
      assert agg.totals.active == 1
      assert agg.totals.registered == 2
      assert Enum.find(agg.repos, &(&1.status == :offline)).error == :econnrefused
    end
  end

  describe "TUI.render/2" do
    test "renders a bordered aggregate status frame with per-repo running table and backoff queue" do
      out = TUI.render(aggregate_fixture(), color: false, columns: 118, next_refresh_seconds: 1)

      assert out =~ "╭─ SMITHY STATUS "
      assert out =~ "╮"
      assert out =~ "│ Repos: 1 active / 2 registered"
      assert out =~ "│ Total Agents: 1/3 across repos"
      assert out =~ "│ Throughput: 42 tps"
      assert out =~ "│ Tokens: in 1,000 | out 500 | total 1,500"
      assert out =~ "│ Generated: 2026-05-12T12:00:00Z"
      assert out =~ "│ Next refresh: 1s"

      assert out =~ "├─ [smithy] Running"

      assert out =~
               "ID       STAGE          PID      AGE / TURN   TOKENS     SESSION        EVENT"

      assert out =~ "PER-167"
      assert out =~ "In Progress"
      assert out =~ "12345"
      assert out =~ "2m 5s / 3"
      assert out =~ "1,500"
      assert out =~ "abcd...567890"
      assert out =~ "command output streaming"

      assert out =~ "├─ [substrate] OFFLINE — daemon down"
      assert out =~ "├─ Backoff queue"
      assert out =~ "PER-199"
      assert out =~ "attempt=2"
      assert out =~ "rate limited"
      assert out =~ "q quit"
      assert out =~ "╰"
    end

    test "renders legacy aggregate data with empty repos gracefully" do
      config = two_repo_config()
      client = fn _ -> {:ok, sample_payload(2)} end
      agg = Status.collect(config, client)

      out = TUI.render(%{agg | repos: [%{hd(agg.repos) | payload: %{}}]}, color: false)

      assert out =~ "SMITHY STATUS"
      assert out =~ "Repos: 2 active / 2 registered"
      assert out =~ "[smithy]"
      assert out =~ "No active agents"
    end

    test "renders OFFLINE repos in red when color is enabled" do
      config = two_repo_config()
      client = fn _ -> {:error, :econnrefused} end
      agg = Status.collect(config, client)
      out = TUI.render(agg, color: true)

      assert out =~ IO.ANSI.bright()
      assert out =~ IO.ANSI.red()
      assert out =~ "OFFLINE"
      assert out =~ "daemon down"
    end

    test "scroll offset changes the visible repo rows when the frame is taller than the terminal" do
      aggregate =
        aggregate_fixture()
        |> put_in([:repos, Access.at(0), :payload, "running"], [
          %{"issue_identifier" => "PER-1", "state" => "Todo"},
          %{"issue_identifier" => "PER-2", "state" => "Todo"},
          %{"issue_identifier" => "PER-3", "state" => "Todo"},
          %{"issue_identifier" => "PER-4", "state" => "Todo"}
        ])

      top = TUI.render(aggregate, color: false, columns: 100, terminal_rows: 16, scroll_offset: 0)

      scrolled =
        TUI.render(aggregate, color: false, columns: 100, terminal_rows: 16, scroll_offset: 6)

      assert top =~ "PER-1"
      refute top =~ "PER-4"
      assert scrolled =~ "PER-4"
      refute scrolled =~ "PER-1"
    end
  end

  describe "TUI.run/2" do
    test "renders a frame, exits on q, and restores terminal state" do
      pid = self()
      aggregate = aggregate_fixture()

      assert :ok =
               TUI.run(Config.defaults(),
                 collect: fn _ -> aggregate end,
                 terminal_size: fn -> {100, 20} end,
                 write_frame: fn frame -> send(pid, {:frame, frame}) end,
                 read_key: fn interval_ms, tty? ->
                   send(pid, {:read_key, interval_ms, tty?})
                   :quit
                 end,
                 capture_stty: fn -> "saved-terminal-mode" end,
                 enter_terminal: fn -> send(pid, :entered_terminal) end,
                 restore_terminal: fn mode -> send(pid, {:restored_terminal, mode}) end
               )

      assert_received :entered_terminal
      assert_received {:frame, frame}
      assert frame =~ "SMITHY STATUS"
      assert_received {:read_key, 1_000, true}
      assert_received {:restored_terminal, "saved-terminal-mode"}
    end
  end
end
