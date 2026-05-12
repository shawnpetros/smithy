defmodule Smithy.CLITest do
  use ExUnit.Case, async: true

  alias Smithy.CLI

  describe "dispatch/1" do
    test "no args prints usage" do
      assert {:ok, out} = CLI.dispatch([])
      assert out =~ "Smithy v"
      assert out =~ "USAGE"
    end

    test "version" do
      assert {:ok, "smithy " <> _} = CLI.dispatch(["version"])
      assert {:ok, "smithy " <> _} = CLI.dispatch(["--version"])
    end

    test "help flag" do
      assert {:ok, out} = CLI.dispatch(["--help"])
      assert out =~ "COMMANDS"
    end

    test "unknown command yields error" do
      assert {:error, {:unknown_command, "wat"}} = CLI.dispatch(["wat"])
    end

    test "add-repo without args is a usage error" do
      assert {:error, :usage} = CLI.dispatch(["add-repo"])
    end

    test "daemon without action is a usage error" do
      assert {:error, :usage} = CLI.dispatch(["daemon"])
    end
  end

  describe "add-repo end-to-end (mocked deps)" do
    alias Smithy.Commands.AddRepo

    test "writes config and installs plist" do
      pid = self()

      deps = %{
        load: fn -> {:ok, Smithy.Config.defaults()} end,
        write: fn cfg ->
          send(pid, {:wrote, cfg})
          :ok
        end,
        install: fn repo, _cfg ->
          send(pid, {:installed, repo.slug})
          {:ok, "/tmp/foo.plist"}
        end
      }

      assert {:ok, out} = AddRepo.run(["smithy", "/tmp/smithy"], %{}, deps)
      assert out =~ "registered smithy"
      assert out =~ "/tmp/foo.plist"
      assert_received {:wrote, %{repos: [%{slug: "smithy", port: 4001}]}}
      assert_received {:installed, "smithy"}
    end

    test "rejects duplicate slug" do
      cfg = Smithy.Config.defaults() |> Map.put(:repos, [
        %{slug: "smithy", path: "/x", workflow: "WORKFLOW.md", port: 4001}
      ])

      deps = %{
        load: fn -> {:ok, cfg} end,
        write: fn _ -> :ok end,
        install: fn _, _ -> {:ok, ""} end
      }

      assert {:error, {:duplicate_slug, "smithy"}} =
               Smithy.Commands.AddRepo.run(["smithy", "/y"], %{}, deps)
    end
  end

  describe "daemon command (mocked deps)" do
    alias Smithy.Commands.DaemonCmd

    test "start with no slug iterates all repos" do
      cfg = Smithy.Config.defaults() |> Map.put(:repos, [
        %{slug: "a", path: "/x", workflow: "WORKFLOW.md", port: 4001},
        %{slug: "b", path: "/y", workflow: "WORKFLOW.md", port: 4002}
      ])

      pid = self()

      deps = %{
        load: fn -> {:ok, cfg} end,
        load_action: fn slug -> send(pid, {:start, slug}); {:ok, ""} end,
        unload_action: fn _ -> {:ok, ""} end,
        restart_action: fn _ -> {:ok, ""} end
      }

      assert {:ok, out} = DaemonCmd.run(["start"], %{}, deps)
      assert_received {:start, "a"}
      assert_received {:start, "b"}
      assert out =~ "start a: ok"
      assert out =~ "start b: ok"
    end

    test "unknown action errors" do
      deps = %{
        load: fn -> {:ok, Smithy.Config.defaults()} end,
        load_action: fn _ -> {:ok, ""} end,
        unload_action: fn _ -> {:ok, ""} end,
        restart_action: fn _ -> {:ok, ""} end
      }

      assert {:error, :usage} = Smithy.Commands.DaemonCmd.run(["bogus"], %{}, deps)
    end
  end

  describe "status command (mocked deps)" do
    alias Smithy.Commands.StatusCmd

    test "renders TUI" do
      cfg = Smithy.Config.defaults() |> Map.put(:repos, [
        %{slug: "a", path: "/x", workflow: "WORKFLOW.md", port: 4001}
      ])

      agg = %{
        repos: [%{slug: "a", port: 4001, url: "http://localhost:4001/api/v1/state",
                  status: :online, error: nil,
                  payload: %{"counts" => %{"running" => 0}, "running" => []}}],
        totals: %{registered: 1, active: 1, agents_running: 0,
                  tokens_in: 0, tokens_out: 0, tokens_total: 0},
        generated_at: "2026-05-12T00:00:00Z"
      }

      deps = %{
        load: fn -> {:ok, cfg} end,
        collect: fn _ -> agg end,
        write_dashboard: fn _ -> {:ok, "/tmp/d.html"} end,
        open: fn _ -> {:ok, ""} end
      }

      assert {:ok, out} = StatusCmd.run([], %{}, deps)
      assert out =~ "SMITHY STATUS"
      assert out =~ "[a]"
    end

    test "--json emits JSON" do
      cfg = Smithy.Config.defaults() |> Map.put(:repos, [])

      agg = %{
        repos: [],
        totals: %{registered: 0, active: 0, agents_running: 0,
                  tokens_in: 0, tokens_out: 0, tokens_total: 0},
        generated_at: "2026-05-12T00:00:00Z"
      }

      deps = %{
        load: fn -> {:ok, cfg} end,
        collect: fn _ -> agg end,
        write_dashboard: fn _ -> {:ok, ""} end,
        open: fn _ -> {:ok, ""} end
      }

      assert {:ok, out} = StatusCmd.run([], %{json: true}, deps)
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["totals"]["registered"] == 0
    end
  end
end
