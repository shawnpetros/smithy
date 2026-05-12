defmodule SymphonyElixir.Modes.TriagerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.AgentConfig
  alias SymphonyElixir.Handoff.Triage
  alias SymphonyElixir.Modes.Triager

  # A stub adapter that records calls and returns canned responses.
  # Mirrors the pattern in ReviewerTest exactly: invocations tagged via
  # Process dictionary so concurrent tests do not stomp on each other.
  defmodule StubAdapter do
    def start_session(workspace, opts) do
      tag = Keyword.fetch!(opts, :__tag__)

      Agent.update(tag, fn state ->
        Map.update!(state, :start_calls, &[%{workspace: workspace, opts: opts} | &1])
      end)

      Agent.get(tag, & &1.start_response)
    end

    def run_turn(session, prompt, issue, opts) do
      Agent.update(session.tag, fn state ->
        Map.update!(state, :turn_calls, &[%{prompt: prompt, issue: issue, opts: opts} | &1])
      end)

      # Optional side effect: write TRIAGE.md as if the agent did.
      case Agent.get(session.tag, & &1.triage_md_to_write) do
        nil ->
          :noop

        {path, body} ->
          File.write!(path, body)
      end

      Agent.get(session.tag, & &1.turn_response)
    end

    def stop_session(session) do
      Agent.update(session.tag, fn state -> Map.put(state, :stopped, true) end)
      :ok
    end
  end

  setup do
    {:ok, tag} =
      Agent.start_link(fn ->
        %{
          start_calls: [],
          turn_calls: [],
          stopped: false,
          start_response: {:ok, %{tag: nil}},
          turn_response: {:ok, %{status: :ok}},
          triage_md_to_write: nil
        }
      end)

    # Seed start_response to actually include the live tag so run_turn finds it.
    Agent.update(tag, fn state ->
      put_in(state.start_response, {:ok, %{tag: tag}})
    end)

    workspace = tmp_workspace()
    on_exit(fn -> File.rm_rf!(workspace) end)

    %{tag: tag, workspace: workspace}
  end

  defp tmp_workspace do
    dir = Path.join(System.tmp_dir!(), "symphony_triager_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp agent_config(overrides \\ %{}) do
    base = %AgentConfig{
      mode: :triager,
      runtime: :codex,
      persona: "triager",
      mcp: [],
      tier: "low"
    }

    struct(base, overrides)
  end

  defp issue do
    %{
      identifier: "PER-77",
      title: "Improve the dashboard",
      description: "Make the dashboard faster.",
      branch_name: "smithy/per-77-dashboard",
      labels: ["agent-ready", "elixir"]
    }
  end

  defp proceed_triage_md do
    """
    ---
    decision: proceed
    reasons:
      - "Where: identifies lib/foo/bar.ex"
      - "What: adds X behavior"
      - "Acceptance: testable assertion provided"
      - "Ambiguity: none"
    ---
    """
  end

  defp flag_triage_md do
    """
    ---
    decision: flag
    reasons:
      - "Where: 'the dashboard' is ambiguous"
      - "What: 'faster' is not a concrete delta"
      - "Acceptance: no testable criterion"
      - "Ambiguity: at least three plausible implementations"
    gap_comment: |
      This ticket cannot be executed autonomously in its current form.
      Specific gaps:
      - Target module is unspecified.
      - 'Improve performance' lacks a measurable target.
      To re-queue: address the gaps above, remove `needs-spec`, add
      `agent-ready`, and move to Ready for Dev.
    ---
    """
  end

  defp malformed_triage_md do
    """
    ---
    not yaml at all: [
    ---
    """
  end

  defp fake_persona_loader do
    fn _path ->
      {:ok,
       %SymphonyElixir.Personas.Persona{
         name: "triager",
         description: "stub",
         mode: :triager,
         runtime: :codex,
         body:
           "Triage {{identifier}}: {{title}}\nLabels: {{labels}}\nBranch: {{branch}}\nDescription:\n{{description}}"
       }}
    end
  end

  # The StubAdapter reads its tag from the :__tag__ session opt. We pass
  # the tag through a thin TaggedAdapter wrapper that pulls it from the
  # Process dictionary (same pattern as ReviewerTest).
  defmodule TaggedAdapter do
    def start_session(workspace, opts) do
      tag = Process.get(:triager_test_tag)
      StubAdapter.start_session(workspace, [{:__tag__, tag} | opts])
    end

    def run_turn(session, prompt, issue, opts),
      do: StubAdapter.run_turn(session, prompt, issue, opts)

    def stop_session(session), do: StubAdapter.stop_session(session)
  end

  describe "next_state/1" do
    test "proceed maps to In Progress" do
      triage = %Triage{decision: :proceed}
      assert Triager.next_state({:proceed, triage}) == "In Progress"
    end

    test "flag maps to Backlog" do
      triage = %Triage{decision: :flag, gap_comment: "fill it in"}
      assert Triager.next_state({:flag, triage}) == "Backlog"
    end

    test "blocked maps to Todo (no transition)" do
      assert Triager.next_state({:blocked, "anything"}) == "Todo"
    end
  end

  describe "label_action/1" do
    test "proceed maps to :none" do
      triage = %Triage{decision: :proceed}
      assert Triager.label_action({:proceed, triage}) == :none
    end

    test "flag adds needs-spec and removes agent-ready" do
      triage = %Triage{decision: :flag, gap_comment: "x"}

      assert Triager.label_action({:flag, triage}) ==
               {:both, %{add: ["needs-spec"], remove: ["agent-ready"]}}
    end

    test "blocked adds harness-blocked" do
      assert Triager.label_action({:blocked, "x"}) == {:add, ["harness-blocked"]}
    end
  end

  describe "workpad_comment/1" do
    test "proceed returns nil" do
      triage = %Triage{decision: :proceed}
      assert Triager.workpad_comment({:proceed, triage}) == nil
    end

    test "flag returns the gap_comment" do
      gap = "These are the gaps."
      triage = %Triage{decision: :flag, gap_comment: gap}
      assert Triager.workpad_comment({:flag, triage}) == gap
    end

    test "blocked prefixes the reason for the workpad" do
      assert Triager.workpad_comment({:blocked, "TRIAGE.md unreadable"}) ==
               "Harness BLOCKED at triage: TRIAGE.md unreadable"
    end
  end

  describe "disallowed_tools/0" do
    test "includes all Linear write tools" do
      tools = Triager.disallowed_tools()
      assert "mcp__linear__save_issue" in tools
      assert "mcp__linear__save_comment" in tools
      assert "mcp__linear__save_document" in tools
      assert "mcp__linear__save_milestone" in tools
      assert "mcp__linear__save_project" in tools
      assert "mcp__linear__delete_comment" in tools
      assert "mcp__linear__delete_attachment" in tools
      assert "mcp__linear__create_attachment" in tools
      assert "mcp__linear__create_issue_label" in tools
    end

    test "does not block Write or Edit (triager needs them for TRIAGE.md)" do
      tools = Triager.disallowed_tools()
      refute "Edit" in tools
      refute "Write" in tools
    end
  end

  describe "run/4 with stub adapter" do
    test "valid proceed TRIAGE.md returns {:proceed, triage}", %{tag: tag, workspace: workspace} do
      Process.put(:triager_test_tag, tag)

      triage_path = Path.join(workspace, "TRIAGE.md")

      Agent.update(tag, fn state ->
        %{state | triage_md_to_write: {triage_path, proceed_triage_md()}}
      end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader()
      ]

      assert {:ok, {:proceed, %Triage{decision: :proceed, reasons: reasons}}} =
               Triager.run(issue(), workspace, agent_config(), opts)

      assert is_list(reasons)
      assert length(reasons) == 4

      # Verify adapter lifecycle
      state = Agent.get(tag, & &1)
      assert length(state.start_calls) == 1
      assert length(state.turn_calls) == 1
      assert state.stopped == true

      # Verify denylist and mode were passed to the adapter
      [start_call] = state.start_calls
      assert "mcp__linear__save_issue" in start_call.opts[:disallowed_tools]
      refute "Edit" in start_call.opts[:disallowed_tools]
      refute "Write" in start_call.opts[:disallowed_tools]
      assert start_call.opts[:mode] == :triager
      assert start_call.opts[:tier] == "low"
    end

    test "valid flag TRIAGE.md returns {:flag, triage} with gap_comment", %{
      tag: tag,
      workspace: workspace
    } do
      Process.put(:triager_test_tag, tag)
      triage_path = Path.join(workspace, "TRIAGE.md")

      Agent.update(tag, fn state ->
        %{state | triage_md_to_write: {triage_path, flag_triage_md()}}
      end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader()
      ]

      assert {:ok, {:flag, %Triage{decision: :flag, gap_comment: gap}}} =
               Triager.run(issue(), workspace, agent_config(), opts)

      assert is_binary(gap)
      assert gap =~ "cannot be executed autonomously"
      assert gap =~ "To re-queue"
    end

    test "missing TRIAGE.md returns {:blocked, _}", %{tag: tag, workspace: workspace} do
      Process.put(:triager_test_tag, tag)
      # No triage_md_to_write configured; file will not exist.

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader()
      ]

      assert {:ok, {:blocked, reason}} = Triager.run(issue(), workspace, agent_config(), opts)
      assert reason =~ "TRIAGE.md unreadable"
    end

    test "malformed TRIAGE.md returns {:blocked, _}", %{tag: tag, workspace: workspace} do
      Process.put(:triager_test_tag, tag)
      triage_path = Path.join(workspace, "TRIAGE.md")

      Agent.update(tag, fn state ->
        %{state | triage_md_to_write: {triage_path, malformed_triage_md()}}
      end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader()
      ]

      assert {:ok, {:blocked, reason}} = Triager.run(issue(), workspace, agent_config(), opts)
      assert reason =~ "TRIAGE.md unreadable"
    end

    test "renders persona body with issue + labels vars (no diff)", %{
      tag: tag,
      workspace: workspace
    } do
      Process.put(:triager_test_tag, tag)
      triage_path = Path.join(workspace, "TRIAGE.md")

      Agent.update(tag, fn state ->
        %{state | triage_md_to_write: {triage_path, proceed_triage_md()}}
      end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader()
      ]

      assert {:ok, {:proceed, _}} = Triager.run(issue(), workspace, agent_config(), opts)

      [turn_call] = Agent.get(tag, & &1.turn_calls)
      assert turn_call.prompt =~ "PER-77"
      assert turn_call.prompt =~ "Improve the dashboard"
      assert turn_call.prompt =~ "agent-ready, elixir"
      assert turn_call.prompt =~ "smithy/per-77-dashboard"
      # No diff section in the triager prompt.
      refute turn_call.prompt =~ "{{diff}}"
    end

    test "persona_loader error bubbles back as {:error, _}", %{tag: tag, workspace: workspace} do
      Process.put(:triager_test_tag, tag)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fn _ -> {:error, "boom"} end
      ]

      assert {:error, {:persona_load_failed, "boom"}} =
               Triager.run(issue(), workspace, agent_config(), opts)

      assert Agent.get(tag, & &1.start_calls) == []
    end

    test "adapter start_session error bubbles back as {:error, _}", %{
      tag: tag,
      workspace: workspace
    } do
      Process.put(:triager_test_tag, tag)
      Agent.update(tag, fn state -> %{state | start_response: {:error, :spawn_failed}} end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader()
      ]

      assert {:error, :spawn_failed} = Triager.run(issue(), workspace, agent_config(), opts)
    end

    test "adapter run_turn error bubbles back and session is stopped", %{
      tag: tag,
      workspace: workspace
    } do
      Process.put(:triager_test_tag, tag)
      Agent.update(tag, fn state -> %{state | turn_response: {:error, :turn_failed}} end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader()
      ]

      assert {:error, :turn_failed} = Triager.run(issue(), workspace, agent_config(), opts)
      assert Agent.get(tag, & &1.stopped) == true
    end

    test "persona not found returns {:error, {:persona_not_found, _, _}}", %{
      tag: tag,
      workspace: workspace
    } do
      Process.put(:triager_test_tag, tag)

      opts = [
        adapter: TaggedAdapter,
        # No persona_loader override; let real resolution run against a non-
        # existent persona name in a project_dir that has no .smithy dir.
        project_dir: workspace
      ]

      config = agent_config(%{persona: "nonexistent_triager_persona_xyz"})

      assert {:error, {:persona_not_found, "nonexistent_triager_persona_xyz", _candidates}} =
               Triager.run(issue(), workspace, config, opts)
    end
  end

  describe "persona resolution" do
    test "loads from priv/personas when persona name matches a shipped file" do
      # The triager.md persona ships in priv/personas/triager.md.
      workspace = tmp_workspace()
      on_exit(fn -> File.rm_rf!(workspace) end)
      {:ok, tag} = Agent.start_link(fn -> %{seen_path: nil} end)

      loader = fn path ->
        Agent.update(tag, fn state -> %{state | seen_path: path} end)

        {:ok,
         %SymphonyElixir.Personas.Persona{
           name: "triager",
           description: "stub",
           mode: :triager,
           runtime: :codex,
           body: "body"
         }}
      end

      triage_path = Path.join(workspace, "TRIAGE.md")
      File.write!(triage_path, proceed_triage_md())

      defmodule NoopAdapter do
        def start_session(_w, _o), do: {:ok, :session}
        def run_turn(_s, _p, _i, _o), do: {:ok, %{}}
        def stop_session(_s), do: :ok
      end

      opts = [
        adapter: NoopAdapter,
        persona_loader: loader,
        project_dir: workspace
      ]

      assert {:ok, {:proceed, _}} = Triager.run(issue(), workspace, agent_config(), opts)

      path = Agent.get(tag, & &1.seen_path)
      assert path != nil

      assert String.ends_with?(path, "priv/personas/triager.md") or
               String.contains?(path, "/priv/personas/triager.md")
    end

    test "falls back to .smithy/personas in project_dir when priv shipped file is absent" do
      workspace = tmp_workspace()
      on_exit(fn -> File.rm_rf!(workspace) end)
      project_dir = tmp_workspace()
      on_exit(fn -> File.rm_rf!(project_dir) end)

      repo_persona_path = Path.join([project_dir, ".smithy/personas/custom-triager.md"])
      File.mkdir_p!(Path.dirname(repo_persona_path))
      File.write!(repo_persona_path, "---\nname: x\ndescription: y\n---\nbody")

      triage_path = Path.join(workspace, "TRIAGE.md")
      File.write!(triage_path, proceed_triage_md())

      {:ok, tag} = Agent.start_link(fn -> %{seen_path: nil} end)

      loader = fn path ->
        Agent.update(tag, fn state -> %{state | seen_path: path} end)

        {:ok,
         %SymphonyElixir.Personas.Persona{
           name: "custom-triager",
           description: "stub",
           body: "body"
         }}
      end

      defmodule NoopAdapter2 do
        def start_session(_w, _o), do: {:ok, :session}
        def run_turn(_s, _p, _i, _o), do: {:ok, %{}}
        def stop_session(_s), do: :ok
      end

      opts = [
        adapter: NoopAdapter2,
        persona_loader: loader,
        project_dir: project_dir
      ]

      config = agent_config(%{persona: "custom-triager"})

      assert {:ok, {:proceed, _}} = Triager.run(issue(), workspace, config, opts)

      seen = Agent.get(tag, & &1.seen_path)
      assert seen == repo_persona_path
    end
  end
end
