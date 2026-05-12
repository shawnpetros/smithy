defmodule SymphonyElixir.Modes.Outcomes do
  @moduledoc """
  Applies mode outcomes to Linear and the persistent workpad.

  Reviewer and triager agents only return structured outcomes. This module is
  the single place that translates those outcomes into state transitions, label
  changes, and workpad notes.
  """

  require Logger

  alias SymphonyElixir.Handoff.{Review, Triage}
  alias SymphonyElixir.{Linear.Issue, Telemetry, Tracker, Workpad}

  @type reviewer_outcome ::
          {:pass, Review.t()}
          | {:fail, Review.t()}
          | {:blocked, term()}

  @type triager_outcome ::
          {:proceed, Triage.t()}
          | {:flag, Triage.t()}
          | {:blocked, term()}

  @doc """
  Apply the Linear/workpad side effects for a reviewer outcome.
  """
  @spec handle_reviewer_outcome(Issue.t(), reviewer_outcome(), keyword()) :: :ok
  def handle_reviewer_outcome(issue, {:pass, review}, opts) do
    workpad_append(issue, :adversarial_review, format_review_for_workpad(review, "PASS"), opts)
    next_state = if has_label?(issue, "auto-merge"), do: "Merging", else: "Human Review"
    update_issue_state(issue, next_state, opts)
  end

  def handle_reviewer_outcome(issue, {:fail, review}, opts) do
    workpad_append(issue, :adversarial_review, format_review_for_workpad(review, "FAIL"), opts)
    update_issue_state(issue, "Rework", opts)
  end

  def handle_reviewer_outcome(issue, {:blocked, reason}, opts) do
    apply_harness_blocked(issue, reason, opts)
  end

  @doc """
  Apply the Linear/workpad side effects for a triager outcome.
  """
  @spec handle_triager_outcome(Issue.t(), triager_outcome(), keyword()) :: :ok
  def handle_triager_outcome(issue, {:proceed, _triage}, opts) do
    # Builder will be dispatched on the next polling cycle.
    update_issue_state(issue, "In Progress", opts)
  end

  def handle_triager_outcome(issue, {:flag, triage}, opts) do
    workpad_append(issue, :notes, "Triage flagged:\n\n" <> (triage.gap_comment || ""), opts)
    add_label(issue, "needs-spec", opts)
    remove_label(issue, "agent-ready", opts)
    update_issue_state(issue, "Backlog", opts)
  end

  def handle_triager_outcome(issue, {:blocked, reason}, opts) do
    apply_harness_blocked(issue, reason, opts)
  end

  @doc false
  @spec apply_harness_blocked(Issue.t(), term(), keyword()) :: :ok
  def apply_harness_blocked(issue, reason, opts) do
    add_label(issue, "harness-blocked", opts)
    workpad_append(issue, :notes, "Harness BLOCKED: " <> to_string(reason), opts)
  end

  @doc false
  @spec workpad_append(Issue.t(), atom(), String.t(), keyword()) :: :ok
  def workpad_append(issue, section, content, opts) do
    workpad_mod = Keyword.get(opts, :workpad_mod, Workpad)

    case workpad_mod.append_section(issue.id, section, content, []) do
      {:ok, _comment_id} ->
        :ok

      {:error, reason} ->
        Logger.warning("Workpad append failed for #{issue.identifier}: #{inspect(reason)}")
        :ok
    end
  end

  @doc false
  @spec update_issue_state(Issue.t(), String.t(), keyword()) :: :ok
  def update_issue_state(%Issue{id: issue_id, identifier: identifier, state: from_state}, state_name, opts) do
    tracker_mod = Keyword.get(opts, :tracker_mod, Tracker)

    case tracker_mod.update_issue_state(issue_id, state_name) do
      :ok ->
        Telemetry.safe_emit(telemetry_mod(opts), :state_transition,
          ticket: identifier,
          from_state: from_state,
          to_state: state_name,
          run_id: Keyword.get(opts, :run_id)
        )

        :ok

      {:error, reason} ->
        Logger.warning("State transition to #{state_name} failed for #{identifier}: #{inspect(reason)}")
        :ok
    end
  end

  @doc false
  @spec add_label(Issue.t(), String.t(), keyword()) :: :ok
  def add_label(issue, label_name, opts) do
    tracker_mod = Keyword.get(opts, :tracker_mod, Tracker)

    try do
      case tracker_mod.add_label(issue, label_name) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Label add #{label_name} failed for #{issue.identifier}: #{inspect(reason)}")
          :ok
      end
    rescue
      UndefinedFunctionError ->
        Logger.warning("Tracker.add_label/2 not implemented; skipping label #{label_name} for #{issue.identifier}")
        :ok
    end
  end

  @doc false
  @spec remove_label(Issue.t(), String.t(), keyword()) :: :ok
  def remove_label(issue, label_name, opts) do
    tracker_mod = Keyword.get(opts, :tracker_mod, Tracker)

    try do
      case tracker_mod.remove_label(issue, label_name) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Label remove #{label_name} failed for #{issue.identifier}: #{inspect(reason)}")
          :ok
      end
    rescue
      UndefinedFunctionError ->
        Logger.warning("Tracker.remove_label/2 not implemented; skipping label #{label_name} for #{issue.identifier}")
        :ok
    end
  end

  @doc false
  @spec format_review_for_workpad(Review.t() | map(), String.t()) :: String.t()
  def format_review_for_workpad(%Review{} = review, status_label) do
    do_format_review_for_workpad(review.findings, review.notes, status_label)
  end

  def format_review_for_workpad(%{findings: findings} = review, status_label) do
    do_format_review_for_workpad(findings, Map.get(review, :notes), status_label)
  end

  defp do_format_review_for_workpad(findings, notes, status_label) do
    findings_block =
      findings
      |> List.wrap()
      |> Enum.map_join("\n", fn
        %{finding: finding, grade: grade} -> "- [#{grade}] #{finding}"
        other -> "- #{inspect(other)}"
      end)

    notes_block =
      case notes do
        nil -> ""
        "" -> ""
        text when is_binary(text) -> "\n\n" <> text
        other -> "\n\n" <> inspect(other)
      end

    "**#{status_label}**\n\n#{findings_block}#{notes_block}"
  end

  defp has_label?(%Issue{labels: labels}, target) when is_list(labels) do
    Enum.any?(labels, fn
      %{name: name} -> name == target
      name when is_binary(name) -> name == target
      _ -> false
    end)
  end

  defp has_label?(_, _), do: false

  defp telemetry_mod(opts), do: Keyword.get(opts, :telemetry_mod, Telemetry)
end
