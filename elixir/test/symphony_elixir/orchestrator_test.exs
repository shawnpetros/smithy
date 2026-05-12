defmodule SymphonyElixir.OrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.AgentConfig

  describe "select_agent_config_for_issue/1 (sub-pass B)" do
    test "agents block absent entirely yields vanilla Codex builder defaults" do
      issue = %Issue{
        id: "issue-select-builder",
        identifier: "MT-SELECT-1",
        title: "Select builder",
        description: "Default agents block; only builder is populated",
        state: "In Progress",
        url: "https://example.org/issues/MT-SELECT-1",
        labels: []
      }

      assert {:builder, %AgentConfig{} = agent_config} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)

      assert agent_config.mode == :builder
      assert agent_config.runtime == :codex
    end

    test "normalizes Todo state name casing and surrounding spaces before selecting triager" do
      write_workflow_with_agents!(triager: triager_yaml())

      for state <- ["todo", "Todo", " Todo "] do
        issue = issue_for_select("issue-select-tri-#{state}", "MT-SELECT-TRI-NORM", state)

        assert {:triager, %AgentConfig{mode: :triager}} =
                 Orchestrator.select_agent_config_for_issue_for_test(issue)
      end
    end

    test "returns :reviewer for Adversarial Review when reviewers list is non-empty" do
      write_workflow_with_agents!(reviewers: [reviewer_yaml()])

      issue = %Issue{
        id: "issue-select-rev",
        identifier: "MT-SELECT-REV",
        title: "Adversarial Review picks reviewer",
        description: "Reviewer branch active",
        state: "Adversarial Review",
        url: "https://example.org/issues/MT-SELECT-REV",
        labels: []
      }

      assert {:reviewer, %AgentConfig{mode: :reviewer, runtime: :claude_code}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)
    end

    test "returns :builder for Adversarial Review when agents.reviewers is an explicit empty list" do
      write_workflow_with_agents!(reviewers: [])

      issue = %Issue{
        id: "issue-select-rev-empty",
        identifier: "MT-SELECT-REV-EMPTY",
        title: "Adversarial Review without reviewers falls back to builder",
        description: "",
        state: "Adversarial Review",
        url: "https://example.org/issues/MT-SELECT-REV-EMPTY",
        labels: []
      }

      assert {:builder, %AgentConfig{mode: :builder}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)
    end

    test "returns the first reviewer when multiple reviewers are configured" do
      write_workflow_with_agents!(
        reviewers: [
          reviewer_yaml("reviewer.md", "claude_code"),
          reviewer_yaml("architect-reviewer.md", "codex")
        ]
      )

      issue =
        issue_for_select("issue-select-rev-panel", "MT-SELECT-REV-PANEL", "Adversarial Review")

      assert {:reviewer, %AgentConfig{mode: :reviewer, persona: "reviewer.md"}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)
    end

    test "returns :triager for Todo when triager is configured" do
      write_workflow_with_agents!(triager: triager_yaml())

      issue = %Issue{
        id: "issue-select-tri",
        identifier: "MT-SELECT-TRI",
        title: "Todo picks triager",
        description: "Triager branch active",
        state: "Todo",
        url: "https://example.org/issues/MT-SELECT-TRI",
        labels: []
      }

      assert {:triager, %AgentConfig{mode: :triager}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)
    end

    test "returns :builder for Todo when no triager is configured" do
      issue = %Issue{
        id: "issue-select-todo",
        identifier: "MT-SELECT-TODO",
        title: "Todo without triager picks builder",
        description: "",
        state: "Todo",
        url: "https://example.org/issues/MT-SELECT-TODO",
        labels: []
      }

      assert {:builder, %AgentConfig{mode: :builder}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)
    end

    test "triager-only config triages Todo and fails loudly when In Progress needs a builder" do
      write_workflow_with_agents!(builder: nil, triager: triager_yaml())

      assert {:triager, %AgentConfig{mode: :triager}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue_for_select("issue-select-tri-only", "MT-SELECT-TRI-ONLY", "Todo"))

      assert_raise ArgumentError, ~r/agents\.builder is required/, fn ->
        Orchestrator.select_agent_config_for_issue_for_test(issue_for_select("issue-select-no-builder", "MT-SELECT-NO-BUILDER", "In Progress"))
      end
    end

    test "returns :builder for In Progress even with a triager configured" do
      # Triager only fires on Todo. Once the issue transitions, the builder
      # takes over.
      write_workflow_with_agents!(triager: triager_yaml())

      issue = %Issue{
        id: "issue-select-inprog",
        identifier: "MT-SELECT-INPROG",
        title: "In Progress always picks builder",
        description: "",
        state: "In Progress",
        url: "https://example.org/issues/MT-SELECT-INPROG",
        labels: []
      }

      assert {:builder, %AgentConfig{mode: :builder}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)
    end
  end

  describe "revalidate_issue_for_dispatch/2" do
    test "uses refreshed issue state when Adversarial Review becomes Rework before dispatch" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["Todo", "In Progress", "Adversarial Review", "Rework"]
      )

      stale_issue =
        issue_for_select("issue-revalidate-race", "MT-REVALIDATE-RACE", "Adversarial Review")

      refreshed_issue = %{stale_issue | state: "Rework"}
      fetcher = fn ["issue-revalidate-race"] -> {:ok, [refreshed_issue]} end

      assert {:ok, ^refreshed_issue} =
               Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

      assert {:builder, %AgentConfig{mode: :builder}} =
               Orchestrator.select_agent_config_for_issue_for_test(refreshed_issue)
    end
  end

  defp reviewer_yaml(persona \\ "reviewer.md", runtime \\ "claude_code") do
    """
        - mode: reviewer
          runtime: #{runtime}
          persona: #{persona}
    """
  end

  defp triager_yaml do
    """
        mode: triager
        runtime: claude_code
        persona: triager.md
    """
  end

  defp write_workflow_with_agents!(opts) do
    builder = Keyword.get(opts, :builder, :default)
    reviewers = Keyword.get(opts, :reviewers, :omitted)
    triager = Keyword.get(opts, :triager)

    agents_block =
      ["agents:"]
      |> append_builder_yaml(builder)
      |> append_reviewers_yaml(reviewers)
      |> append_triager_yaml(triager)
      |> Enum.join("\n")

    path = Workflow.workflow_file_path()
    base = File.read!(path)

    # Insert the agents block just before the closing `---` of the front matter.
    [front, prompt] = String.split(base, ~r/^---\s*$/m, parts: 3) |> Enum.take(-2)

    new_content =
      "---\n" <> String.trim_trailing(front, "\n") <> "\n" <> agents_block <> "\n---" <> prompt

    File.write!(path, new_content)
    SymphonyElixir.WorkflowStore.force_reload()
    :ok
  end

  defp append_builder_yaml(lines, :default) do
    lines ++
      [
        "  builder:",
        "    mode: builder",
        "    runtime: codex"
      ]
  end

  defp append_builder_yaml(lines, nil), do: lines ++ ["  builder: null"]
  defp append_builder_yaml(lines, :omitted), do: lines

  defp append_reviewers_yaml(lines, :omitted), do: lines
  defp append_reviewers_yaml(lines, []), do: lines ++ ["  reviewers: []"]

  defp append_reviewers_yaml(lines, reviewers) when is_list(reviewers) do
    lines ++ ["  reviewers:" | Enum.map(reviewers, &String.trim_trailing/1)]
  end

  defp append_triager_yaml(lines, nil), do: lines

  defp append_triager_yaml(lines, triager) when is_binary(triager) do
    lines ++
      ["  triager:" | String.split(String.trim_trailing(triager), "\n")]
  end

  defp issue_for_select(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Select #{identifier}",
      description: "",
      state: state,
      url: "https://example.org/issues/#{identifier}",
      labels: []
    }
  end
end
