defmodule SymphonyElixir.Modes.OutcomesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Handoff.{Review, Triage}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Modes.Outcomes

  test "reviewer PASS appends review summary and transitions auto-merge tickets to Merging" do
    tracker_table = new_stub_table()
    workpad_table = new_stub_table()
    telemetry_table = new_stub_table()

    issue = issue("issue-review-pass", "PER-REVIEW-PASS", "Adversarial Review", [%{name: "auto-merge"}])

    review = %Review{
      status: :pass,
      findings: [%{finding: "No blockers", grade: :polish}],
      notes: "Ready."
    }

    assert :ok =
             Outcomes.handle_reviewer_outcome(issue, {:pass, review},
               tracker_mod: stub_tracker_mod(tracker_table),
               workpad_mod: stub_workpad_mod(workpad_table),
               telemetry_mod: stub_telemetry_mod(telemetry_table),
               run_id: "run-review-pass"
             )

    assert [{:append_section, "issue-review-pass", :adversarial_review, content, []}] =
             read_stub_calls(workpad_table)

    assert content =~ "**PASS**"
    assert content =~ "[polish] No blockers"
    assert content =~ "Ready."

    assert read_stub_calls(tracker_table) == [
             {:update_issue_state, "issue-review-pass", "Merging"}
           ]

    assert read_stub_calls(telemetry_table) == [
             {:emit, :state_transition,
              [
                ticket: "PER-REVIEW-PASS",
                from_state: "Adversarial Review",
                to_state: "Merging",
                run_id: "run-review-pass"
              ]}
           ]
  end

  test "triager FLAG records gap, updates labels, and moves to Backlog" do
    tracker_table = new_stub_table()
    workpad_table = new_stub_table()
    telemetry_table = new_stub_table()
    issue = issue("issue-triage-flag", "PER-TRIAGE-FLAG", "Todo", ["agent-ready"])

    triage = %Triage{
      decision: :flag,
      reasons: ["Missing acceptance"],
      gap_comment: "Please add concrete validation."
    }

    assert :ok =
             Outcomes.handle_triager_outcome(issue, {:flag, triage},
               tracker_mod: stub_tracker_mod(tracker_table),
               workpad_mod: stub_workpad_mod(workpad_table),
               telemetry_mod: stub_telemetry_mod(telemetry_table),
               run_id: "run-triage-flag"
             )

    assert [{:append_section, "issue-triage-flag", :notes, content, []}] =
             read_stub_calls(workpad_table)

    assert content =~ "Triage flagged"
    assert content =~ "Please add concrete validation."

    assert read_stub_calls(tracker_table) == [
             {:add_label, issue, "needs-spec"},
             {:remove_label, issue, "agent-ready"},
             {:update_issue_state, "issue-triage-flag", "Backlog"}
           ]

    assert read_stub_calls(telemetry_table) == [
             {:emit, :state_transition,
              [
                ticket: "PER-TRIAGE-FLAG",
                from_state: "Todo",
                to_state: "Backlog",
                run_id: "run-triage-flag"
              ]}
           ]
  end

  defp issue(id, identifier, state, labels) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Outcome test #{identifier}",
      description: "",
      state: state,
      url: "https://example.test/#{identifier}",
      labels: labels
    }
  end

  defp new_stub_table do
    :ets.new(:outcomes_stub_table, [:public, :ordered_set])
  end

  defp read_stub_calls(table) do
    table
    |> :ets.tab2list()
    |> Enum.reject(fn {key, _} -> key == :__seq__ end)
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.map(fn {_seq, call} -> call end)
  end

  defp stub_tracker_mod(table) do
    :persistent_term.put({__MODULE__, :tracker_table, self()}, table)
    SymphonyElixir.Modes.OutcomesTest.TrackerStub
  end

  defp stub_workpad_mod(table) do
    :persistent_term.put({__MODULE__, :workpad_table, self()}, table)
    SymphonyElixir.Modes.OutcomesTest.WorkpadStub
  end

  defp stub_telemetry_mod(table) do
    :persistent_term.put({__MODULE__, :telemetry_table, self()}, table)
    SymphonyElixir.Modes.OutcomesTest.TelemetryStub
  end

  defmodule TrackerStub do
    @moduledoc false

    def update_issue_state(issue_id, state_name) do
      table = :persistent_term.get({SymphonyElixir.Modes.OutcomesTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:update_issue_state, issue_id, state_name}})
      :ok
    end

    def add_label(issue, label_name) do
      table = :persistent_term.get({SymphonyElixir.Modes.OutcomesTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:add_label, issue, label_name}})
      :ok
    end

    def remove_label(issue, label_name) do
      table = :persistent_term.get({SymphonyElixir.Modes.OutcomesTest, :tracker_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:remove_label, issue, label_name}})
      :ok
    end
  end

  defmodule WorkpadStub do
    @moduledoc false

    def append_section(issue_id, section, content, opts) do
      table = :persistent_term.get({SymphonyElixir.Modes.OutcomesTest, :workpad_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:append_section, issue_id, section, content, opts}})
      {:ok, "stub-comment-#{seq}"}
    end
  end

  defmodule TelemetryStub do
    @moduledoc false

    def emit(kind, opts) do
      table = :persistent_term.get({SymphonyElixir.Modes.OutcomesTest, :telemetry_table, self()})
      seq = :ets.update_counter(table, :__seq__, {2, 1}, {:__seq__, 0})
      :ets.insert(table, {seq, {:emit, kind, opts}})
      :ok
    end
  end
end
