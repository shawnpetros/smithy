defmodule SymphonyElixir.Modes.ReviewerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.AgentConfig
  alias SymphonyElixir.Handoff.Review
  alias SymphonyElixir.Modes.Reviewer

  # A stub adapter that records calls and returns canned responses. Injected
  # via opts so we never spawn a real Codex / Claude Code subprocess. We tag
  # invocations with a unique :tag (via Process dictionary) so concurrent
  # tests do not stomp on each other.
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

      # Optional side effect for the test: write REVIEW.md as if the agent did.
      case Agent.get(session.tag, & &1.review_md_to_write) do
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
          review_md_to_write: nil
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
    dir = Path.join(System.tmp_dir!(), "symphony_reviewer_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp agent_config(overrides \\ %{}) do
    base = %AgentConfig{
      mode: :reviewer,
      runtime: :claude_code,
      persona: "reviewer",
      mcp: [],
      tier: "sonnet"
    }

    struct(base, overrides)
  end

  defp issue do
    %{
      identifier: "PER-42",
      title: "Make the thing work",
      description: "A thing should do the thing.",
      branch_name: "smithy/per-42-thing",
      labels: []
    }
  end

  defp adapter_opts(tag) do
    [
      adapter: StubAdapter,
      __unused_tag__: tag
    ]
  end

  defp pass_review_md do
    """
    ---
    status: pass
    findings: []
    notes: ship it
    ---
    """
  end

  defp fail_review_md do
    """
    ---
    status: fail
    findings:
      - finding: parser panics on empty input
        grade: blocker
    notes: send back
    ---
    """
  end

  defp malformed_review_md do
    """
    ---
    not yaml at all: [
    ---
    """
  end

  # Persona loader stub that returns a minimal persona without touching disk.
  defp fake_persona_loader do
    fn _path ->
      {:ok,
       %SymphonyElixir.Personas.Persona{
         name: "reviewer",
         description: "stub",
         mode: :reviewer,
         runtime: :claude_code,
         body: "Review {{identifier}}: {{title}} for {{branch}}.\nDiff:\n{{diff}}"
       }}
    end
  end

  defp fake_diff_fetcher(diff \\ "diff --git a/foo b/foo\n") do
    fn _workspace, _issue -> {:ok, diff} end
  end

  # The StubAdapter reads its tag from the :__tag__ session opt. Inject it
  # into the adapter's start_session opts via a thin shim. We pass the tag
  # through `:adapter_extra_opts`-style mechanism: since Reviewer does not
  # accept that, we wrap the adapter at module level. Simpler: have the
  # adapter pull the tag from `opts[:__tag__]` and require tests to put it
  # there. To do that without modifying Reviewer's opt list, we override
  # start_session opts by injecting a wrapper adapter.
  defmodule TaggedAdapter do
    def start_session(workspace, opts) do
      tag = Process.get(:reviewer_test_tag)
      StubAdapter.start_session(workspace, [{:__tag__, tag} | opts])
    end

    def run_turn(session, prompt, issue, opts),
      do: StubAdapter.run_turn(session, prompt, issue, opts)

    def stop_session(session), do: StubAdapter.stop_session(session)
  end

  describe "next_state/2" do
    test "pass maps to Human Review by default" do
      review = %Review{status: :pass}
      assert Reviewer.next_state({:pass, review}, []) == "Human Review"
    end

    test "pass with :auto_merge maps to Merging" do
      review = %Review{status: :pass}
      assert Reviewer.next_state({:pass, review}, auto_merge: true) == "Merging"
    end

    test "pass with :auto_merge false maps to Human Review" do
      review = %Review{status: :pass}
      assert Reviewer.next_state({:pass, review}, auto_merge: false) == "Human Review"
    end

    test "fail maps to Rework" do
      review = %Review{status: :fail, findings: [%{finding: "x", grade: :blocker}]}
      assert Reviewer.next_state({:fail, review}, []) == "Rework"
    end

    test "fail with :auto_merge still maps to Rework" do
      review = %Review{status: :fail, findings: [%{finding: "x", grade: :blocker}]}
      assert Reviewer.next_state({:fail, review}, auto_merge: true) == "Rework"
    end

    test "blocked maps to Adversarial Review (no transition)" do
      assert Reviewer.next_state({:blocked, "anything"}, []) == "Adversarial Review"
    end
  end

  describe "disallowed_tools/0" do
    test "includes all Linear write tools" do
      tools = Reviewer.disallowed_tools()
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

    test "does not block Write or Edit (reviewer needs them for REVIEW.md)" do
      tools = Reviewer.disallowed_tools()
      refute "Edit" in tools
      refute "Write" in tools
    end
  end

  describe "run/4 with stub adapter" do
    test "valid pass REVIEW.md returns {:pass, review}", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)

      review_path = Path.join(workspace, "REVIEW.md")

      Agent.update(tag, fn state ->
        %{state | review_md_to_write: {review_path, pass_review_md()}}
      end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader(),
        diff_fetcher: fake_diff_fetcher()
      ]

      assert {:ok, {:pass, %Review{status: :pass, notes: "ship it"}}} =
               Reviewer.run(issue(), workspace, agent_config(), opts)

      # Verify adapter lifecycle
      state = Agent.get(tag, & &1)
      assert length(state.start_calls) == 1
      assert length(state.turn_calls) == 1
      assert state.stopped == true

      # Verify denylist was passed to the adapter
      [start_call] = state.start_calls
      assert "mcp__linear__save_issue" in start_call.opts[:disallowed_tools]
      refute "Edit" in start_call.opts[:disallowed_tools]
      refute "Write" in start_call.opts[:disallowed_tools]
      assert start_call.opts[:mode] == :reviewer
      assert start_call.opts[:tier] == "sonnet"

      _ = adapter_opts(tag)
    end

    test "valid fail REVIEW.md returns {:fail, review}", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)
      review_path = Path.join(workspace, "REVIEW.md")

      Agent.update(tag, fn state ->
        %{state | review_md_to_write: {review_path, fail_review_md()}}
      end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader(),
        diff_fetcher: fake_diff_fetcher()
      ]

      assert {:ok, {:fail, %Review{status: :fail, findings: findings}}} =
               Reviewer.run(issue(), workspace, agent_config(), opts)

      assert [%{grade: :blocker}] = findings
    end

    test "missing REVIEW.md returns {:blocked, _}", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)
      # No review_md_to_write configured; file will not exist.

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader(),
        diff_fetcher: fake_diff_fetcher()
      ]

      assert {:ok, {:blocked, reason}} =
               Reviewer.run(issue(), workspace, agent_config(), opts)

      assert reason =~ "REVIEW.md unreadable"
    end

    test "malformed REVIEW.md returns {:blocked, _}", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)
      review_path = Path.join(workspace, "REVIEW.md")

      Agent.update(tag, fn state ->
        %{state | review_md_to_write: {review_path, malformed_review_md()}}
      end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader(),
        diff_fetcher: fake_diff_fetcher()
      ]

      assert {:ok, {:blocked, reason}} =
               Reviewer.run(issue(), workspace, agent_config(), opts)

      assert reason =~ "REVIEW.md unreadable"
    end

    test "renders persona body with issue + diff vars", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)
      review_path = Path.join(workspace, "REVIEW.md")

      Agent.update(tag, fn state ->
        %{state | review_md_to_write: {review_path, pass_review_md()}}
      end)

      diff = "diff --git a/x b/x\n+hi\n"

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader(),
        diff_fetcher: fake_diff_fetcher(diff)
      ]

      assert {:ok, {:pass, _}} = Reviewer.run(issue(), workspace, agent_config(), opts)

      [turn_call] = Agent.get(tag, & &1.turn_calls)
      assert turn_call.prompt =~ "PER-42"
      assert turn_call.prompt =~ "Make the thing work"
      assert turn_call.prompt =~ "smithy/per-42-thing"
      assert turn_call.prompt =~ diff
    end

    test "diff_fetcher error bubbles back as {:error, _}", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader(),
        diff_fetcher: fn _w, _i -> {:error, :diff_unavailable} end
      ]

      assert {:error, :diff_unavailable} =
               Reviewer.run(issue(), workspace, agent_config(), opts)

      # Adapter must not be touched if diff fetch fails.
      assert Agent.get(tag, & &1.start_calls) == []
    end

    test "persona_loader error bubbles back as {:error, _}", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fn _ -> {:error, "boom"} end,
        diff_fetcher: fake_diff_fetcher()
      ]

      assert {:error, {:persona_load_failed, "boom"}} =
               Reviewer.run(issue(), workspace, agent_config(), opts)

      assert Agent.get(tag, & &1.start_calls) == []
    end

    test "adapter start_session error bubbles back as {:error, _}", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)
      Agent.update(tag, fn state -> %{state | start_response: {:error, :spawn_failed}} end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader(),
        diff_fetcher: fake_diff_fetcher()
      ]

      assert {:error, :spawn_failed} =
               Reviewer.run(issue(), workspace, agent_config(), opts)
    end

    test "adapter run_turn error bubbles back as {:error, _}", %{tag: tag, workspace: workspace} do
      Process.put(:reviewer_test_tag, tag)
      Agent.update(tag, fn state -> %{state | turn_response: {:error, :turn_failed}} end)

      opts = [
        adapter: TaggedAdapter,
        persona_loader: fake_persona_loader(),
        diff_fetcher: fake_diff_fetcher()
      ]

      assert {:error, :turn_failed} =
               Reviewer.run(issue(), workspace, agent_config(), opts)

      # Session should still be stopped on the error path.
      assert Agent.get(tag, & &1.stopped) == true
    end

    test "persona not found returns {:error, {:persona_not_found, _, _}}", %{
      tag: tag,
      workspace: workspace
    } do
      Process.put(:reviewer_test_tag, tag)

      opts = [
        adapter: TaggedAdapter,
        diff_fetcher: fake_diff_fetcher(),
        # No persona_loader override; let real resolution run against a non-
        # existent persona name in a project_dir that has no .smithy dir.
        project_dir: workspace
      ]

      config = agent_config(%{persona: "nonexistent_reviewer_persona_xyz"})

      assert {:error, {:persona_not_found, "nonexistent_reviewer_persona_xyz", _candidates}} =
               Reviewer.run(issue(), workspace, config, opts)
    end
  end

  describe "persona resolution" do
    test "loads from priv/personas when persona name matches a shipped file" do
      # The reviewer.md persona ships in priv/personas/reviewer.md.
      workspace = tmp_workspace()
      on_exit(fn -> File.rm_rf!(workspace) end)
      {:ok, tag} = Agent.start_link(fn -> %{seen_path: nil} end)

      loader = fn path ->
        Agent.update(tag, fn state -> %{state | seen_path: path} end)

        {:ok,
         %SymphonyElixir.Personas.Persona{
           name: "reviewer",
           description: "stub",
           mode: :reviewer,
           runtime: :claude_code,
           body: "body"
         }}
      end

      review_path = Path.join(workspace, "REVIEW.md")
      File.write!(review_path, pass_review_md())

      # Use an adapter that does nothing.
      defmodule NoopAdapter do
        def start_session(_w, _o), do: {:ok, :session}
        def run_turn(_s, _p, _i, _o), do: {:ok, %{}}
        def stop_session(_s), do: :ok
      end

      opts = [
        adapter: NoopAdapter,
        persona_loader: loader,
        diff_fetcher: fake_diff_fetcher(),
        project_dir: workspace
      ]

      assert {:ok, {:pass, _}} = Reviewer.run(issue(), workspace, agent_config(), opts)

      path = Agent.get(tag, & &1.seen_path)
      assert path != nil

      assert String.ends_with?(path, "priv/personas/reviewer.md") or
               String.contains?(path, "/priv/personas/reviewer.md")
    end

    test "falls back to .smithy/personas in project_dir when priv shipped file is absent" do
      workspace = tmp_workspace()
      on_exit(fn -> File.rm_rf!(workspace) end)
      project_dir = tmp_workspace()
      on_exit(fn -> File.rm_rf!(project_dir) end)

      repo_persona_path = Path.join([project_dir, ".smithy/personas/custom-reviewer.md"])
      File.mkdir_p!(Path.dirname(repo_persona_path))
      File.write!(repo_persona_path, "---\nname: x\ndescription: y\n---\nbody")

      review_path = Path.join(workspace, "REVIEW.md")
      File.write!(review_path, pass_review_md())

      {:ok, tag} = Agent.start_link(fn -> %{seen_path: nil} end)

      loader = fn path ->
        Agent.update(tag, fn state -> %{state | seen_path: path} end)

        {:ok,
         %SymphonyElixir.Personas.Persona{
           name: "custom-reviewer",
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
        diff_fetcher: fake_diff_fetcher(),
        project_dir: project_dir
      ]

      config = agent_config(%{persona: "custom-reviewer"})

      assert {:ok, {:pass, _}} = Reviewer.run(issue(), workspace, config, opts)

      seen = Agent.get(tag, & &1.seen_path)
      assert seen == repo_persona_path
    end
  end

  describe "default_diff_fetcher/2" do
    test "falls back to git when gh pr diff fails (in an empty workspace)", %{workspace: workspace} do
      # Both `gh pr diff` and `git diff main...HEAD` will fail in an empty
      # workspace. The contract is that we surface the failure as
      # {:error, {:diff_unavailable, _}}.
      result = Reviewer.default_diff_fetcher(workspace, %{})
      assert match?({:error, {:diff_unavailable, _}}, result)
    end
  end
end
