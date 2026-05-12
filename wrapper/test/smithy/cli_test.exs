defmodule Smithy.CLITest do
  use ExUnit.Case, async: false

  alias Smithy.{Acknowledge, CLI, Config}

  # Tests that hit CLI.dispatch/1 directly touch the on-disk acknowledgement
  # at ~/.smithy/config.toml via Smithy.Acknowledge. Point HOME at a temp
  # dir for the duration of the suite and seed an acknowledged config so the
  # default dispatch paths reach their handlers as if the gate had passed.
  # The "gating" describe block explicitly clears + asserts the gate behavior.

  setup_all do
    tmp_dir =
      Path.join(System.tmp_dir!(), "smithy-cli-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    previous_home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)

    seeded =
      Config.defaults()
      |> Map.put(:acknowledged_at, "2026-05-12T00:00:00Z")

    :ok = Config.write(seeded)

    on_exit(fn ->
      if previous_home, do: System.put_env("HOME", previous_home)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

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

    test "add-repo without args is a usage error (gate already passed)" do
      assert {:error, :usage} = CLI.dispatch(["add-repo"])
    end

    test "daemon without action is a usage error (gate already passed)" do
      assert {:error, :usage} = CLI.dispatch(["daemon"])
    end
  end

  describe "hold-harmless gating" do
    setup do
      :ok = Acknowledge.reset()
      on_exit(fn ->
        seeded =
          Config.defaults()
          |> Map.put(:acknowledged_at, "2026-05-12T00:00:00Z")

        :ok = Config.write(seeded)
      end)

      :ok
    end

    # First-run gated commands prompt inline. Tests can't easily simulate
    # stdin, but the EOF path through Acknowledge.run/1 returns :declined
    # which lets us assert the gate fires without acknowledging.

    test "add-repo prompts inline on first run; declines on EOF" do
      assert {:error, :declined} = CLI.dispatch(["add-repo", "x", "/tmp/x"])
    end

    test "remove-repo prompts inline; declines on EOF" do
      assert {:error, :declined} = CLI.dispatch(["remove-repo", "x"])
    end

    test "daemon prompts inline; declines on EOF" do
      assert {:error, :declined} = CLI.dispatch(["daemon", "start"])
    end

    test "status NOT gated (read-only)" do
      # status reaches its handler (then may fail for other reasons), but
      # it does NOT trip the gate.
      assert {:ok, _} = CLI.dispatch(["status", "--json"])
    end

    test "version NOT gated" do
      assert {:ok, _} = CLI.dispatch(["version"])
    end

    test "acknowledge --auto records the acknowledgement" do
      assert {:ok, _} =
               CLI.dispatch(["acknowledge", "--auto"])

      assert Acknowledge.acknowledged?()
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
