defmodule Smithy.DashboardTest do
  use ExUnit.Case, async: true

  alias Smithy.Dashboard

  defp sample_running(n) do
    for i <- 1..n do
      %{
        "issue_identifier" => "PER-#{100 + i}",
        "state" => "In Progress",
        "session_id" => "session-abc-#{i}",
        "started_at" =>
          DateTime.utc_now()
          |> DateTime.add(-120, :second)
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601(),
        "last_event" => "tool_use",
        "tokens" => %{"input_tokens" => 1000, "output_tokens" => 500, "total_tokens" => 1500}
      }
    end
  end

  defp online_repo(slug, port, running_n \\ 1) do
    running = sample_running(running_n)

    %{
      slug: slug,
      port: port,
      url: "http://localhost:#{port}/api/v1/state",
      status: :online,
      error: nil,
      payload: %{
        "generated_at" => "2026-05-12T12:00:00Z",
        "counts" => %{"running" => running_n, "retrying" => 0, "max_agents" => 3},
        "running" => running,
        "retrying" => [],
        "codex_totals" => %{
          "input_tokens" => running_n * 1000,
          "output_tokens" => running_n * 500,
          "total_tokens" => running_n * 1500
        },
        "rate_limits" => %{}
      }
    }
  end

  defp offline_repo(slug, port) do
    %{
      slug: slug,
      port: port,
      url: "http://localhost:#{port}/api/v1/state",
      status: :offline,
      error: :econnrefused,
      payload: nil
    }
  end

  defp aggregate(repos) do
    registered = length(repos)
    active = Enum.count(repos, &(&1.status == :online))

    %{
      repos: repos,
      totals: %{
        registered: registered,
        active: active,
        agents_running: active,
        agents_capacity: nil,
        throughput_tps: 0,
        tokens_in: 0,
        tokens_out: 0,
        tokens_total: 0
      },
      generated_at: "2026-05-12T12:00:00Z"
    }
  end

  describe "aggregate_html/1" do
    test "contains no iframes" do
      html = Dashboard.aggregate_html(aggregate([online_repo("smithy", 4001)]))
      refute html =~ "<iframe"
    end

    test "includes meta refresh tag" do
      html = Dashboard.aggregate_html(aggregate([online_repo("smithy", 4001)]))
      assert html =~ ~r/meta http-equiv="refresh"/i
    end

    test "empty state when no repos" do
      html = Dashboard.aggregate_html(aggregate([]))
      assert html =~ "smithy add-repo"
      refute html =~ ~r/<section class="repo-section"/
    end

    test "shows cross-repo totals header" do
      html =
        Dashboard.aggregate_html(
          aggregate([online_repo("smithy", 4001), online_repo("substrate", 4002, 2)])
        )

      assert html =~ "active"
      assert html =~ "registered"
    end

    test "shows slug in online repo section" do
      html = Dashboard.aggregate_html(aggregate([online_repo("my-repo", 4001, 2)]))
      assert html =~ "my-repo"
      assert html =~ "4001"
    end

    test "shows running agents in online repo" do
      html = Dashboard.aggregate_html(aggregate([online_repo("smithy", 4001, 3)]))
      assert html =~ "PER-101"
      assert html =~ "PER-102"
      assert html =~ "PER-103"
    end

    test "offline repo renders offline badge" do
      html = Dashboard.aggregate_html(aggregate([offline_repo("ghost", 4099)]))
      assert html =~ "ghost"
      assert html =~ "Offline"
      assert html =~ "repo-offline"
    end

    test "online repo renders live badge, not offline" do
      html = Dashboard.aggregate_html(aggregate([online_repo("smithy", 4001)]))
      assert html =~ "status-badge-live"
      refute html =~ ~r/repo-card repo-offline/
    end

    test "per-repo accent color uses slug hue" do
      html = Dashboard.aggregate_html(aggregate([online_repo("smithy", 4001)]))
      assert html =~ "--repo-h:"
    end

    test "mixed online/offline repos both appear" do
      html =
        Dashboard.aggregate_html(
          aggregate([online_repo("live-repo", 4001), offline_repo("dead-repo", 4002)])
        )

      assert html =~ "live-repo"
      assert html =~ "dead-repo"
      assert html =~ "status-badge-live"
      assert html =~ "repo-offline"
    end

    test "global metric grid absent for single repo" do
      html = Dashboard.aggregate_html(aggregate([online_repo("solo", 4001)]))
      refute html =~ ~r/<section class="metric-grid"/
    end

    test "global metric grid present for multiple repos" do
      html =
        Dashboard.aggregate_html(
          aggregate([online_repo("a", 4001), online_repo("b", 4002)])
        )

      assert html =~ "metric-grid"
    end
  end

  describe "write_aggregate_html/2 (pre-collected aggregate)" do
    test "writes a file and returns the path" do
      agg = aggregate([online_repo("smithy", 4001)])
      assert {:ok, path} = Dashboard.write_aggregate_html(%{}, agg)
      assert String.ends_with?(path, "dashboard.html")
      assert File.exists?(path)
      html = File.read!(path)
      assert html =~ "smithy"
    end
  end
end
