defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.AgentConfig

  describe "run/3 mode + agent_config threading (sub-pass A)" do
    test "accepts :mode and :agent_config opts and logs mode=:builder" do
      {test_root, codex_binary, workspace_root, template_repo} = build_fake_codex_fixture()

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
          codex_command: "#{codex_binary} app-server"
        )

        issue = %Issue{
          id: "issue-mode-opts",
          identifier: "MT-OPT-1",
          title: "Mode opts threading",
          description: "Verify run/3 accepts the new opts",
          state: "In Progress",
          url: "https://example.org/issues/MT-OPT-1",
          labels: []
        }

        agent_config = %AgentConfig{
          mode: :builder,
          runtime: :codex,
          persona: nil,
          mcp: [],
          tier: "medium"
        }

        state_fetcher = fn [_id] -> {:ok, [%{issue | state: "Done"}]} end

        log =
          capture_log(fn ->
            assert :ok =
                     AgentRunner.run(issue, nil,
                       mode: :builder,
                       agent_config: agent_config,
                       issue_state_fetcher: state_fetcher
                     )
          end)

        assert log =~ "Starting agent run for"
        assert log =~ "mode=builder"
      after
        File.rm_rf(test_root)
      end
    end

    test "defaults mode to :builder when not provided and logs the default" do
      {test_root, codex_binary, workspace_root, template_repo} = build_fake_codex_fixture()

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
          codex_command: "#{codex_binary} app-server"
        )

        issue = %Issue{
          id: "issue-mode-default",
          identifier: "MT-OPT-2",
          title: "Mode default threading",
          description: "Verify run/3 defaults mode when not provided",
          state: "In Progress",
          url: "https://example.org/issues/MT-OPT-2",
          labels: []
        }

        state_fetcher = fn [_id] -> {:ok, [%{issue | state: "Done"}]} end

        log =
          capture_log(fn ->
            assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
          end)

        assert log =~ "mode=builder"
      after
        File.rm_rf(test_root)
      end
    end
  end

  defp build_fake_codex_fixture do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-mode-opts-#{System.unique_integer([:positive])}"
      )

    template_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")

    File.mkdir_p!(template_repo)
    File.mkdir_p!(workspace_root)
    File.write!(Path.join(template_repo, "README.md"), "# test")
    System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
    System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", template_repo, "add", "README.md"])
    System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{\"id\":1,\"result\":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-mode-opts\"}}}'
          ;;
        4)
          printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-mode-opts\"}}}'
          printf '%s\\n' '{\"method\":\"turn/completed\"}'
          exit 0
          ;;
        *)
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    {test_root, codex_binary, workspace_root, template_repo}
  end
end
