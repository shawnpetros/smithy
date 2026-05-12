defmodule SymphonyElixir.OrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.AgentConfig

  describe "select_agent_config_for_issue/1 (sub-pass B)" do
    test "returns :builder for any active issue when no reviewer/triager is configured" do
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

    test "returns :builder for Adversarial Review when reviewers list is empty" do
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

  defp reviewer_yaml do
    """
        - mode: reviewer
          runtime: claude_code
          persona: reviewer.md
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
    reviewers = Keyword.get(opts, :reviewers, [])
    triager = Keyword.get(opts, :triager)

    agents_block =
      ["agents:"]
      |> append_builder_yaml()
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

  defp append_builder_yaml(lines) do
    lines ++
      [
        "  builder:",
        "    mode: builder",
        "    runtime: codex"
      ]
  end

  defp append_reviewers_yaml(lines, []), do: lines

  defp append_reviewers_yaml(lines, reviewers) when is_list(reviewers) do
    lines ++ ["  reviewers:" | Enum.map(reviewers, &String.trim_trailing/1)]
  end

  defp append_triager_yaml(lines, nil), do: lines

  defp append_triager_yaml(lines, triager) when is_binary(triager) do
    lines ++
      ["  triager:" | String.split(String.trim_trailing(triager), "\n")]
  end
end
