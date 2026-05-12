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

  describe "run/3 with mode: :reviewer (sub-pass B)" do
    setup :stub_workspace_root

    test "PASS outcome appends to workpad and transitions to Human Review", %{workspace_root: _root} do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()

      issue =
        review_issue("issue-rev-pass", "MT-REV-PASS", state: "Adversarial Review", labels: [])

      review = %SymphonyElixir.Handoff.Review{
        status: :pass,
        findings: [%{finding: "Looks good", grade: :polish}],
        notes: "All clear."
      }

      reviewer_stub = fn ^issue, _workspace, _agent_config, _opts ->
        {:ok, {:pass, review}}
      end

      agent_config = reviewer_agent_config()

      assert :ok =
               AgentRunner.run(issue, nil,
                 mode: :reviewer,
                 agent_config: agent_config,
                 reviewer_mod: stub_reviewer(reviewer_stub),
                 tracker_mod: stub_tracker_mod(tracker_table),
                 workpad_mod: stub_workpad_mod(workpad_table)
               )

      assert read_stub_calls(tracker_table) == [
               {:update_issue_state, "issue-rev-pass", "Human Review"}
             ]

      assert [{:append_section, "issue-rev-pass", :adversarial_review, content, _opts}] =
               read_stub_calls(workpad_table)

      assert content =~ "**PASS**"
      assert content =~ "[polish] Looks good"
      assert content =~ "All clear."
    end

    test "PASS outcome with auto-merge label transitions to Merging" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()

      issue =
        review_issue("issue-rev-merge", "MT-REV-MERGE",
          state: "Adversarial Review",
          labels: [%{name: "auto-merge"}]
        )

      review = %SymphonyElixir.Handoff.Review{
        status: :pass,
        findings: [],
        notes: nil
      }

      reviewer_stub = fn _issue, _workspace, _agent_config, _opts ->
        {:ok, {:pass, review}}
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 mode: :reviewer,
                 agent_config: reviewer_agent_config(),
                 reviewer_mod: stub_reviewer(reviewer_stub),
                 tracker_mod: stub_tracker_mod(tracker_table),
                 workpad_mod: stub_workpad_mod(workpad_table)
               )

      assert read_stub_calls(tracker_table) == [
               {:update_issue_state, "issue-rev-merge", "Merging"}
             ]
    end

    test "FAIL outcome transitions to Rework and appends FAIL to workpad" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()

      issue = review_issue("issue-rev-fail", "MT-REV-FAIL", state: "Adversarial Review", labels: [])

      review = %SymphonyElixir.Handoff.Review{
        status: :fail,
        findings: [%{finding: "Tests do not pass", grade: :blocker}],
        notes: nil
      }

      reviewer_stub = fn _issue, _workspace, _agent_config, _opts ->
        {:ok, {:fail, review}}
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 mode: :reviewer,
                 agent_config: reviewer_agent_config(),
                 reviewer_mod: stub_reviewer(reviewer_stub),
                 tracker_mod: stub_tracker_mod(tracker_table),
                 workpad_mod: stub_workpad_mod(workpad_table)
               )

      assert read_stub_calls(tracker_table) == [
               {:update_issue_state, "issue-rev-fail", "Rework"}
             ]

      assert [{:append_section, "issue-rev-fail", :adversarial_review, content, _}] =
               read_stub_calls(workpad_table)

      assert content =~ "**FAIL**"
      assert content =~ "[blocker] Tests do not pass"
    end

    test "BLOCKED outcome applies harness-blocked label and notes" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()

      issue =
        review_issue("issue-rev-blocked", "MT-REV-BLOCK", state: "Adversarial Review", labels: [])

      reviewer_stub = fn _issue, _workspace, _agent_config, _opts ->
        {:ok, {:blocked, "REVIEW.md unparseable"}}
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 mode: :reviewer,
                 agent_config: reviewer_agent_config(),
                 reviewer_mod: stub_reviewer(reviewer_stub),
                 tracker_mod: stub_tracker_mod(tracker_table),
                 workpad_mod: stub_workpad_mod(workpad_table)
               )

      assert {:add_label, issue, "harness-blocked"} in read_stub_calls(tracker_table)

      assert Enum.any?(read_stub_calls(workpad_table), fn
               {:append_section, "issue-rev-blocked", :notes, content, _} ->
                 content =~ "Harness BLOCKED"

               _ ->
                 false
             end)
    end

    test "adapter error from reviewer_mod marks issue harness-blocked without crashing" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()

      issue =
        review_issue("issue-rev-err", "MT-REV-ERR", state: "Adversarial Review", labels: [])

      reviewer_stub = fn _issue, _workspace, _agent_config, _opts ->
        {:error, :persona_not_configured}
      end

      log =
        capture_log(fn ->
          assert :ok =
                   AgentRunner.run(issue, nil,
                     mode: :reviewer,
                     agent_config: reviewer_agent_config(),
                     reviewer_mod: stub_reviewer(reviewer_stub),
                     tracker_mod: stub_tracker_mod(tracker_table),
                     workpad_mod: stub_workpad_mod(workpad_table)
                   )
        end)

      assert log =~ "Reviewer mode failed"

      assert {:add_label, issue, "harness-blocked"} in read_stub_calls(tracker_table)
    end
  end

  describe "run/3 with mode: :triager (sub-pass B)" do
    setup :stub_workspace_root

    test "PROCEED outcome transitions to In Progress" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()

      issue = review_issue("issue-tri-proceed", "MT-TRI-OK", state: "Todo", labels: [])

      triage = %SymphonyElixir.Handoff.Triage{
        decision: :proceed,
        reasons: ["Spec is clear"],
        gap_comment: nil
      }

      triager_stub = fn _issue, _workspace, _agent_config, _opts ->
        {:ok, {:proceed, triage}}
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 mode: :triager,
                 agent_config: triager_agent_config(),
                 triager_mod: stub_triager(triager_stub),
                 tracker_mod: stub_tracker_mod(tracker_table),
                 workpad_mod: stub_workpad_mod(workpad_table)
               )

      assert read_stub_calls(tracker_table) == [
               {:update_issue_state, "issue-tri-proceed", "In Progress"}
             ]

      # Proceed does NOT touch the workpad.
      assert read_stub_calls(workpad_table) == []
    end

    test "FLAG outcome adds needs-spec, removes agent-ready, moves to Backlog" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()

      issue = review_issue("issue-tri-flag", "MT-TRI-FLAG", state: "Todo", labels: [])

      triage = %SymphonyElixir.Handoff.Triage{
        decision: :flag,
        reasons: ["Where? Unclear"],
        gap_comment: "Spec missing the target module."
      }

      triager_stub = fn _issue, _workspace, _agent_config, _opts ->
        {:ok, {:flag, triage}}
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 mode: :triager,
                 agent_config: triager_agent_config(),
                 triager_mod: stub_triager(triager_stub),
                 tracker_mod: stub_tracker_mod(tracker_table),
                 workpad_mod: stub_workpad_mod(workpad_table)
               )

      tracker_calls = read_stub_calls(tracker_table)

      assert {:add_label, issue, "needs-spec"} in tracker_calls
      assert {:remove_label, issue, "agent-ready"} in tracker_calls
      assert {:update_issue_state, "issue-tri-flag", "Backlog"} in tracker_calls

      assert [{:append_section, "issue-tri-flag", :notes, content, _}] =
               read_stub_calls(workpad_table)

      assert content =~ "Triage flagged"
      assert content =~ "Spec missing the target module."
    end

    test "BLOCKED outcome applies harness-blocked label and notes" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()

      issue = review_issue("issue-tri-blocked", "MT-TRI-BLOCK", state: "Todo", labels: [])

      triager_stub = fn _issue, _workspace, _agent_config, _opts ->
        {:ok, {:blocked, "TRIAGE.md missing decision"}}
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 mode: :triager,
                 agent_config: triager_agent_config(),
                 triager_mod: stub_triager(triager_stub),
                 tracker_mod: stub_tracker_mod(tracker_table),
                 workpad_mod: stub_workpad_mod(workpad_table)
               )

      assert {:add_label, issue, "harness-blocked"} in read_stub_calls(tracker_table)

      assert Enum.any?(read_stub_calls(workpad_table), fn
               {:append_section, "issue-tri-blocked", :notes, content, _} ->
                 content =~ "Harness BLOCKED"

               _ ->
                 false
             end)
    end
  end

  # --- fixtures + stub plumbing ------------------------------------------

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

  # --- mode-test fixtures ------------------------------------------------

  defp review_issue(id, identifier, opts) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Mode test #{identifier}",
      description: "",
      state: Keyword.get(opts, :state, "Todo"),
      url: "https://example.org/issues/#{identifier}",
      labels: Keyword.get(opts, :labels, [])
    }
  end

  defp reviewer_agent_config do
    %SymphonyElixir.Config.Schema.AgentConfig{
      mode: :reviewer,
      runtime: :claude_code,
      persona: "reviewer.md",
      mcp: [],
      tier: "medium"
    }
  end

  defp triager_agent_config do
    %SymphonyElixir.Config.Schema.AgentConfig{
      mode: :triager,
      runtime: :claude_code,
      persona: "triager.md",
      mcp: [],
      tier: "medium"
    }
  end

  defp stub_workspace_root(_ctx) do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-mode-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    on_exit(fn -> File.rm_rf(workspace_root) end)

    {:ok, workspace_root: workspace_root}
  end

  # The reviewer/triager call tables collect dispatched calls so each test can
  # assert exactly what the runner triggered without needing process mailboxes.
  defp new_stub_table do
    :ets.new(:agent_runner_stub_table, [:public, :ordered_set])
  end

  defp read_stub_calls(table) do
    table
    |> :ets.tab2list()
    |> Enum.reject(fn {key, _} -> key == :__seq__ end)
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.map(fn {_seq, call} -> call end)
  end

  # Stash a fun for the named stub module and route the call through it.
  # We keep one global stub per module per test because Elixir does not allow
  # passing closures across module boundaries the way ETS-backed handles do.
  defp stub_reviewer(fun) when is_function(fun, 4) do
    :persistent_term.put({__MODULE__, :reviewer_stub, self()}, fun)
    SymphonyElixir.AgentRunnerTest.ReviewerStub
  end

  defp stub_triager(fun) when is_function(fun, 4) do
    :persistent_term.put({__MODULE__, :triager_stub, self()}, fun)
    SymphonyElixir.AgentRunnerTest.TriagerStub
  end

  defp stub_tracker_mod(table) do
    :persistent_term.put({__MODULE__, :tracker_table, self()}, table)
    SymphonyElixir.AgentRunnerTest.TrackerStub
  end

  defp stub_workpad_mod(table) do
    :persistent_term.put({__MODULE__, :workpad_table, self()}, table)
    SymphonyElixir.AgentRunnerTest.WorkpadStub
  end

  defmodule ReviewerStub do
    @moduledoc false

    def run(issue, workspace, agent_config, opts) do
      stub_pid = Keyword.get(opts, :stub_pid, self())
      fun = :persistent_term.get({SymphonyElixir.AgentRunnerTest, :reviewer_stub, stub_pid})
      fun.(issue, workspace, agent_config, opts)
    end
  end

  defmodule TriagerStub do
    @moduledoc false

    def run(issue, workspace, agent_config, opts) do
      stub_pid = Keyword.get(opts, :stub_pid, self())
      fun = :persistent_term.get({SymphonyElixir.AgentRunnerTest, :triager_stub, stub_pid})
      fun.(issue, workspace, agent_config, opts)
    end
  end

  defmodule TrackerStub do
    @moduledoc false

    def update_issue_state(issue_id, state_name) do
      table = :persistent_term.get({SymphonyElixir.AgentRunnerTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:update_issue_state, issue_id, state_name}})
      :ok
    end

    def add_label(issue, label_name) do
      table = :persistent_term.get({SymphonyElixir.AgentRunnerTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:add_label, issue, label_name}})
      :ok
    end

    def remove_label(issue, label_name) do
      table = :persistent_term.get({SymphonyElixir.AgentRunnerTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:remove_label, issue, label_name}})
      :ok
    end
  end

  defmodule WorkpadStub do
    @moduledoc false

    def append_section(issue_id, section, content, opts) do
      table = :persistent_term.get({SymphonyElixir.AgentRunnerTest, :workpad_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:append_section, issue_id, section, content, opts}})
      {:ok, "stub-comment-#{seq}"}
    end
  end
end
