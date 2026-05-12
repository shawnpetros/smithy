defmodule SymphonyElixir.Modes.DispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.AgentConfig
  alias SymphonyElixir.Handoff.{Review, Triage}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Modes.Dispatch

  describe "run/4" do
    setup :stub_workspace_root

    test "routes reviewer mode through the injected reviewer and outcome handler" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()
      telemetry_table = new_stub_table()
      issue = issue("issue-dispatch-review", "PER-DISPATCH-REVIEW", "Adversarial Review")

      review = %Review{
        status: :fail,
        findings: [%{finding: "Regression", grade: :blocker}],
        notes: nil
      }

      reviewer_stub = fn ^issue, workspace, %AgentConfig{mode: :reviewer}, opts ->
        assert File.dir?(workspace)
        assert opts[:worker_host] == nil
        {:ok, {:fail, review}}
      end

      assert :ok =
               Dispatch.run(
                 issue,
                 nil,
                 [
                   mode: :reviewer,
                   agent_config: reviewer_agent_config(),
                   reviewer_mod: stub_reviewer(reviewer_stub),
                   tracker_mod: stub_tracker_mod(tracker_table),
                   workpad_mod: stub_workpad_mod(workpad_table),
                   telemetry_mod: stub_telemetry_mod(telemetry_table),
                   run_id: "run-dispatch-review"
                 ],
                 nil
               )

      assert read_stub_calls(tracker_table) == [
               {:update_issue_state, "issue-dispatch-review", "Rework"}
             ]

      assert [{:append_section, "issue-dispatch-review", :adversarial_review, content, []}] =
               read_stub_calls(workpad_table)

      assert content =~ "**FAIL**"
      assert content =~ "[blocker] Regression"

      events = read_stub_calls(telemetry_table)
      assert {:emit, :turn_start, start_opts} = Enum.at(events, 0)
      assert {:emit, :turn_end, end_opts} = Enum.at(events, 1)
      assert {:emit, :state_transition, transition_opts} = Enum.find(events, &match?({:emit, :state_transition, _}, &1))

      assert start_opts[:mode] == :reviewer
      assert start_opts[:run_id] == "run-dispatch-review"
      assert transition_opts[:to_state] == "Rework"
      assert end_opts[:mode] == :reviewer
      assert end_opts[:outcome] == :success
    end

    test "routes triager mode through the injected triager and outcome handler" do
      tracker_table = new_stub_table()
      workpad_table = new_stub_table()
      telemetry_table = new_stub_table()
      issue = issue("issue-dispatch-triage", "PER-DISPATCH-TRIAGE", "Todo")

      triage = %Triage{
        decision: :proceed,
        reasons: ["Ready"],
        gap_comment: nil
      }

      triager_stub = fn ^issue, workspace, %AgentConfig{mode: :triager}, opts ->
        assert File.dir?(workspace)
        assert opts[:worker_host] == nil
        {:ok, {:proceed, triage}}
      end

      assert :ok =
               Dispatch.run(
                 issue,
                 nil,
                 [
                   mode: :triager,
                   agent_config: triager_agent_config(),
                   triager_mod: stub_triager(triager_stub),
                   tracker_mod: stub_tracker_mod(tracker_table),
                   workpad_mod: stub_workpad_mod(workpad_table),
                   telemetry_mod: stub_telemetry_mod(telemetry_table),
                   run_id: "run-dispatch-triage"
                 ],
                 nil
               )

      assert read_stub_calls(tracker_table) == [
               {:update_issue_state, "issue-dispatch-triage", "In Progress"}
             ]

      assert read_stub_calls(workpad_table) == []

      assert Enum.any?(read_stub_calls(telemetry_table), fn
               {:emit, :turn_end, opts} ->
                 opts[:mode] == :triager and opts[:outcome] == :success

               _ ->
                 false
             end)
    end
  end

  defp stub_workspace_root(_ctx) do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dispatch-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    on_exit(fn -> File.rm_rf(workspace_root) end)

    :ok
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Dispatch test #{identifier}",
      description: "",
      state: state,
      url: "https://example.test/#{identifier}",
      labels: []
    }
  end

  defp reviewer_agent_config do
    %AgentConfig{
      mode: :reviewer,
      runtime: :claude_code,
      persona: "reviewer.md",
      mcp: [],
      tier: "medium"
    }
  end

  defp triager_agent_config do
    %AgentConfig{
      mode: :triager,
      runtime: :claude_code,
      persona: "triager.md",
      mcp: [],
      tier: "medium"
    }
  end

  defp new_stub_table do
    :ets.new(:dispatch_stub_table, [:public, :ordered_set])
  end

  defp read_stub_calls(table) do
    table
    |> :ets.tab2list()
    |> Enum.reject(fn {key, _} -> key == :__seq__ end)
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.map(fn {_seq, call} -> call end)
  end

  defp stub_reviewer(fun) when is_function(fun, 4) do
    :persistent_term.put({__MODULE__, :reviewer_stub, self()}, fun)
    SymphonyElixir.Modes.DispatchTest.ReviewerStub
  end

  defp stub_triager(fun) when is_function(fun, 4) do
    :persistent_term.put({__MODULE__, :triager_stub, self()}, fun)
    SymphonyElixir.Modes.DispatchTest.TriagerStub
  end

  defp stub_tracker_mod(table) do
    :persistent_term.put({__MODULE__, :tracker_table, self()}, table)
    SymphonyElixir.Modes.DispatchTest.TrackerStub
  end

  defp stub_workpad_mod(table) do
    :persistent_term.put({__MODULE__, :workpad_table, self()}, table)
    SymphonyElixir.Modes.DispatchTest.WorkpadStub
  end

  defp stub_telemetry_mod(table) do
    :persistent_term.put({__MODULE__, :telemetry_table, self()}, table)
    SymphonyElixir.Modes.DispatchTest.TelemetryStub
  end

  defmodule ReviewerStub do
    @moduledoc false

    def run(issue, workspace, agent_config, opts) do
      fun = :persistent_term.get({SymphonyElixir.Modes.DispatchTest, :reviewer_stub, self()})
      fun.(issue, workspace, agent_config, opts)
    end
  end

  defmodule TriagerStub do
    @moduledoc false

    def run(issue, workspace, agent_config, opts) do
      fun = :persistent_term.get({SymphonyElixir.Modes.DispatchTest, :triager_stub, self()})
      fun.(issue, workspace, agent_config, opts)
    end
  end

  defmodule TrackerStub do
    @moduledoc false

    def update_issue_state(issue_id, state_name) do
      table = :persistent_term.get({SymphonyElixir.Modes.DispatchTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:update_issue_state, issue_id, state_name}})
      :ok
    end

    def add_label(issue, label_name) do
      table = :persistent_term.get({SymphonyElixir.Modes.DispatchTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:add_label, issue, label_name}})
      :ok
    end

    def remove_label(issue, label_name) do
      table = :persistent_term.get({SymphonyElixir.Modes.DispatchTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:remove_label, issue, label_name}})
      :ok
    end
  end

  defmodule WorkpadStub do
    @moduledoc false

    def append_section(issue_id, section, content, opts) do
      table = :persistent_term.get({SymphonyElixir.Modes.DispatchTest, :workpad_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:append_section, issue_id, section, content, opts}})
      {:ok, "stub-comment-#{seq}"}
    end
  end

  defmodule TelemetryStub do
    @moduledoc false

    def emit(kind, opts) do
      table = :persistent_term.get({SymphonyElixir.Modes.DispatchTest, :telemetry_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:emit, kind, opts}})
      :ok
    end
  end
end
