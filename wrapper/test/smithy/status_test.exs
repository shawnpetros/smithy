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
      "counts" => %{"running" => running_n, "retrying" => 0},
      "running" => running,
      "retrying" => [],
      "codex_totals" => %{},
      "rate_limits" => %{}
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
        if String.contains?(url, "4001"), do: {:ok, sample_payload(2)}, else: {:error, :econnrefused}
      end

      agg = Status.collect(config, client)
      assert agg.totals.active == 1
      assert agg.totals.registered == 2
      assert Enum.find(agg.repos, &(&1.status == :offline)).error == :econnrefused
    end
  end

  describe "TUI.render/2" do
    test "renders the header and per-repo blocks" do
      config = two_repo_config()
      client = fn _ -> {:ok, sample_payload(2)} end
      agg = Status.collect(config, client)

      out = TUI.render(agg, color: false)

      assert out =~ "SMITHY STATUS"
      assert out =~ "Repos: 2 active / 2 registered"
      assert out =~ "[smithy]"
      assert out =~ "[substrate]"
      assert out =~ "MT-701"
    end

    test "renders OFFLINE for unreachable repos" do
      config = two_repo_config()
      client = fn _ -> {:error, :econnrefused} end
      agg = Status.collect(config, client)
      out = TUI.render(agg, color: false)
      assert out =~ "OFFLINE"
      assert out =~ "(daemon down)"
    end
  end
end
