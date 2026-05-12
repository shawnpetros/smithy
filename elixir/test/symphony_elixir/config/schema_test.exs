defmodule SymphonyElixir.Config.SchemaTest do
  @moduledoc """
  Block A tests for the three-axis agent config and the Tracker.active_states
  default extension. See `v2/SPEC.md` §Three-axis agent config and §State machine.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{AgentConfig, Agents, Tracker}
  alias SymphonyElixir.Workflow

  describe "Tracker.active_states default" do
    test "includes Adversarial Review and Rework alongside Todo and In Progress" do
      assert %Tracker{}.active_states == [
               "Todo",
               "In Progress",
               "Adversarial Review",
               "Rework"
             ]
    end

    test "parse honors the new default when tracker omits active_states" do
      assert {:ok, settings} = Schema.parse(%{})
      assert settings.tracker.active_states == ["Todo", "In Progress", "Adversarial Review", "Rework"]
    end

    test "parse preserves explicit active_states overrides" do
      assert {:ok, settings} =
               Schema.parse(%{tracker: %{active_states: ["Todo", "In Progress"]}})

      assert settings.tracker.active_states == ["Todo", "In Progress"]
    end
  end

  describe "agents: defaults" do
    test "absent agents block yields a vanilla builder and empty reviewers" do
      assert {:ok, settings} = Schema.parse(%{})

      assert %Agents{} = settings.agents
      assert %AgentConfig{} = settings.agents.builder
      assert settings.agents.builder.mode == :builder
      assert settings.agents.builder.runtime == :codex
      assert settings.agents.builder.persona == nil
      assert settings.agents.builder.mcp == []
      assert settings.agents.builder.tier == "medium"
      assert settings.agents.reviewers == []
      assert settings.agents.triager == nil
    end

    test "empty agents map still yields the vanilla builder default" do
      assert {:ok, settings} = Schema.parse(%{agents: %{}})
      assert settings.agents.builder.mode == :builder
      assert settings.agents.builder.runtime == :codex
      assert settings.agents.reviewers == []
      assert settings.agents.triager == nil
    end
  end

  describe "agents: full block" do
    test "parses builder, reviewers (list), and triager with all fields" do
      assert {:ok, settings} =
               Schema.parse(%{
                 agents: %{
                   builder: %{
                     mode: "builder",
                     runtime: "codex",
                     persona: "builder-default.md",
                     mcp: ["linear-read"],
                     tier: "medium"
                   },
                   reviewers: [
                     %{
                       mode: "reviewer",
                       runtime: "claude_code",
                       persona: "reviewer.md",
                       mcp: [],
                       tier: "sonnet"
                     }
                   ],
                   triager: %{
                     mode: "triager",
                     runtime: "codex",
                     persona: "triager.md",
                     mcp: ["linear-read"],
                     tier: "low"
                   }
                 }
               })

      assert settings.agents.builder.mode == :builder
      assert settings.agents.builder.runtime == :codex
      assert settings.agents.builder.persona == "builder-default.md"
      assert settings.agents.builder.mcp == ["linear-read"]
      assert settings.agents.builder.tier == "medium"

      assert [reviewer] = settings.agents.reviewers
      assert reviewer.mode == :reviewer
      assert reviewer.runtime == :claude_code
      assert reviewer.persona == "reviewer.md"
      assert reviewer.mcp == []
      assert reviewer.tier == "sonnet"

      assert settings.agents.triager.mode == :triager
      assert settings.agents.triager.runtime == :codex
      assert settings.agents.triager.persona == "triager.md"
      assert settings.agents.triager.mcp == ["linear-read"]
      assert settings.agents.triager.tier == "low"
    end

    test "reviewers as length-N list survives parse for forward compat" do
      assert {:ok, settings} =
               Schema.parse(%{
                 agents: %{
                   reviewers: [
                     %{mode: "reviewer", runtime: "claude_code", persona: "reviewer.md"},
                     %{mode: "reviewer", runtime: "codex", persona: "architect-reviewer.md"}
                   ]
                 }
               })

      assert length(settings.agents.reviewers) == 2
      assert Enum.map(settings.agents.reviewers, & &1.persona) ==
               ["reviewer.md", "architect-reviewer.md"]
    end
  end

  describe "agents: invalid input" do
    test "rejects unknown mode value with a clear error" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 agents: %{builder: %{mode: "wizard", runtime: "codex"}}
               })

      assert message =~ "agents.builder.mode"
    end

    test "rejects unknown runtime value with a clear error" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 agents: %{builder: %{mode: "builder", runtime: "ollama"}}
               })

      assert message =~ "agents.builder.runtime"
    end

    test "rejects reviewer missing required mode" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 agents: %{
                   reviewers: [%{runtime: "claude_code", persona: "reviewer.md"}]
                 }
               })

      assert message =~ "agents.reviewers"
      assert message =~ "mode"
    end
  end

  describe "Workflow.parse normalizes the singular reviewer key" do
    setup do
      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-workflow-agents-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_root)
      path = Path.join(tmp_root, "WORKFLOW.md")

      previous = Application.get_env(:symphony_elixir, :workflow_file_path)
      Application.put_env(:symphony_elixir, :workflow_file_path, path)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:symphony_elixir, :workflow_file_path)
        else
          Application.put_env(:symphony_elixir, :workflow_file_path, previous)
        end

        File.rm_rf(tmp_root)
      end)

      {:ok, path: path}
    end

    test "promotes singular reviewer map into a length-1 reviewers list", %{path: path} do
      File.write!(path, """
      ---
      agents:
        builder:
          mode: builder
          runtime: codex
        reviewer:
          mode: reviewer
          runtime: claude_code
          persona: reviewer.md
      ---
      """)

      assert {:ok, %{config: config}} = Workflow.load(path)
      assert get_in(config, ["agents", "reviewer"]) == nil
      assert [reviewer] = get_in(config, ["agents", "reviewers"])
      assert reviewer["mode"] == "reviewer"
      assert reviewer["runtime"] == "claude_code"
      assert reviewer["persona"] == "reviewer.md"
    end

    test "leaves existing reviewers list shape untouched", %{path: path} do
      File.write!(path, """
      ---
      agents:
        reviewers:
          - mode: reviewer
            runtime: claude_code
            persona: reviewer.md
          - mode: reviewer
            runtime: codex
            persona: architect-reviewer.md
      ---
      """)

      assert {:ok, %{config: config}} = Workflow.load(path)
      assert get_in(config, ["agents", "reviewer"]) == nil
      assert length(get_in(config, ["agents", "reviewers"])) == 2
    end

    test "passes through when agents block is absent", %{path: path} do
      File.write!(path, """
      ---
      tracker:
        kind: linear
      ---
      """)

      assert {:ok, %{config: config}} = Workflow.load(path)
      refute Map.has_key?(config, "agents")
    end

    test "end-to-end: singular reviewer is parseable by Schema.parse after normalization", %{path: path} do
      File.write!(path, """
      ---
      agents:
        reviewer:
          mode: reviewer
          runtime: claude_code
          persona: reviewer.md
          tier: sonnet
      ---
      """)

      assert {:ok, %{config: config}} = Workflow.load(path)
      assert {:ok, settings} = Schema.parse(config)
      assert [reviewer] = settings.agents.reviewers
      assert reviewer.mode == :reviewer
      assert reviewer.runtime == :claude_code
      assert reviewer.tier == "sonnet"
    end
  end
end
