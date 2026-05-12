defmodule SymphonyElixir.OrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.AgentConfig

  describe "select_agent_config_for_issue/1 (sub-pass A)" do
    test "returns :builder mode for any active issue in sub-pass A" do
      issue = %Issue{
        id: "issue-select-builder",
        identifier: "MT-SELECT-1",
        title: "Select builder",
        description: "Sub-pass A always picks builder",
        state: "In Progress",
        url: "https://example.org/issues/MT-SELECT-1",
        labels: []
      }

      assert {:builder, %AgentConfig{} = agent_config} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)

      assert agent_config.mode == :builder
      assert agent_config.runtime == :codex
    end

    test "returns :builder for Adversarial Review too (sub-pass B adds reviewer branch)" do
      issue = %Issue{
        id: "issue-select-adv-review",
        identifier: "MT-SELECT-2",
        title: "Select builder for adversarial review in sub-pass A",
        description: "Reviewer branch lands in sub-pass B",
        state: "Adversarial Review",
        url: "https://example.org/issues/MT-SELECT-2",
        labels: []
      }

      assert {:builder, %AgentConfig{}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)
    end

    test "returns :builder for Todo too (sub-pass B adds triager branch)" do
      issue = %Issue{
        id: "issue-select-todo",
        identifier: "MT-SELECT-3",
        title: "Select builder for todo in sub-pass A",
        description: "Triager branch lands in sub-pass B",
        state: "Todo",
        url: "https://example.org/issues/MT-SELECT-3",
        labels: []
      }

      assert {:builder, %AgentConfig{}} =
               Orchestrator.select_agent_config_for_issue_for_test(issue)
    end
  end
end
