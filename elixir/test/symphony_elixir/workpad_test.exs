defmodule SymphonyElixir.WorkpadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workpad

  # In-memory client backed by an Agent. Records calls and serves canned
  # responses so tests run without network IO. Mirrors the pattern used in
  # `test/symphony_elixir/modes/reviewer_test.exs`.
  defmodule StubClient do
    def start_link(initial_comments \\ []) do
      Agent.start_link(fn ->
        %{
          comments_by_issue: initial_comments_by_issue(initial_comments),
          calls: [],
          next_comment_id: 1
        }
      end)
    end

    defp initial_comments_by_issue(initial) when is_list(initial) do
      Enum.reduce(initial, %{}, fn {issue_id, comments}, acc ->
        Map.put(acc, to_string(issue_id), comments)
      end)
    end

    def set_response(pid, key, value) do
      Agent.update(pid, &Map.put(&1, key, value))
    end

    def calls(pid), do: Agent.get(pid, & &1.calls)

    def stored_comments(pid, issue_id) do
      Agent.get(pid, fn state ->
        Map.get(state.comments_by_issue, to_string(issue_id), [])
      end)
    end

    def list_comments(issue_id) do
      pid = current_pid()
      Agent.update(pid, fn state -> %{state | calls: [{:list_comments, issue_id} | state.calls]} end)

      case Agent.get(pid, fn state -> Map.get(state, :list_response) end) do
        nil ->
          comments =
            Agent.get(pid, fn state ->
              Map.get(state.comments_by_issue, to_string(issue_id), [])
            end)

          {:ok, comments}

        response ->
          response
      end
    end

    def create_comment(issue_id, body) do
      pid = current_pid()

      Agent.update(pid, fn state ->
        %{state | calls: [{:create_comment, issue_id, body} | state.calls]}
      end)

      case Agent.get(pid, fn state -> Map.get(state, :create_response) end) do
        nil ->
          comment_id =
            Agent.get_and_update(pid, fn state ->
              id = "stub-comment-#{state.next_comment_id}"
              new_state = %{state | next_comment_id: state.next_comment_id + 1}
              {id, new_state}
            end)

          Agent.update(pid, fn state ->
            existing = Map.get(state.comments_by_issue, to_string(issue_id), [])
            new_comment = %{id: comment_id, body: body}

            %{
              state
              | comments_by_issue: Map.put(state.comments_by_issue, to_string(issue_id), existing ++ [new_comment])
            }
          end)

          {:ok, comment_id}

        response ->
          response
      end
    end

    def update_comment(comment_id, body) do
      pid = current_pid()

      Agent.update(pid, fn state ->
        %{state | calls: [{:update_comment, comment_id, body} | state.calls]}
      end)

      case Agent.get(pid, fn state -> Map.get(state, :update_response) end) do
        nil ->
          Agent.update(pid, fn state ->
            %{state | comments_by_issue: update_stored_comment(state.comments_by_issue, comment_id, body)}
          end)

          {:ok, comment_id}

        response ->
          response
      end
    end

    # The stub stores its Agent pid in the process dictionary so functions can
    # locate it without each call having to thread it through. Set per-test.
    def install(pid) do
      Process.put(__MODULE__, pid)
      pid
    end

    defp current_pid do
      case Process.get(__MODULE__) do
        nil -> raise "StubClient pid not installed for this process"
        pid -> pid
      end
    end

    defp update_stored_comment(comments_by_issue, comment_id, body) do
      Map.new(comments_by_issue, fn {issue_id, comments} ->
        {issue_id, Enum.map(comments, &update_comment_body(&1, comment_id, body))}
      end)
    end

    defp update_comment_body(%{id: comment_id} = comment, comment_id, body), do: %{comment | body: body}
    defp update_comment_body(comment, _comment_id, _body), do: comment
  end

  setup do
    {:ok, pid} = StubClient.start_link()
    StubClient.install(pid)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    %{client: pid}
  end

  describe "find/2" do
    test "returns :not_found when no workpad comment exists", %{client: _pid} do
      assert :not_found = Workpad.find("issue-1", client: StubClient)
    end

    test "returns the workpad comment when one exists", %{client: pid} do
      Agent.update(pid, fn state ->
        %{
          state
          | comments_by_issue: %{
              "issue-1" => [
                %{id: "c-1", body: "Random earlier comment."},
                %{id: "c-2", body: "## Smithy Workpad\n\n### Plan\n\n- [ ] do thing\n"}
              ]
            }
        }
      end)

      assert {:ok, "c-2", body} = Workpad.find("issue-1", client: StubClient)
      assert body =~ "## Smithy Workpad"
    end

    test "recognizes legacy ## Codex Workpad marker for backwards compatibility", %{client: pid} do
      Agent.update(pid, fn state ->
        %{
          state
          | comments_by_issue: %{
              "issue-1" => [
                %{id: "c-1", body: "Random earlier comment."},
                %{id: "c-2", body: "## Codex Workpad\n\n### Plan\n\n- [ ] do thing\n"}
              ]
            }
        }
      end)

      assert {:ok, "c-2", body} = Workpad.find("issue-1", client: StubClient)
      assert body =~ "## Codex Workpad"
    end

    test "ignores comments that only mention the marker mid-body", %{client: pid} do
      Agent.update(pid, fn state ->
        %{
          state
          | comments_by_issue: %{
              "issue-1" => [
                %{id: "c-1", body: "I love the ## Smithy Workpad pattern btw."}
              ]
            }
        }
      end)

      assert :not_found = Workpad.find("issue-1", client: StubClient)
    end

    test "surfaces client errors", %{client: pid} do
      StubClient.set_response(pid, :list_response, {:error, :boom})
      assert {:error, :boom} = Workpad.find("issue-1", client: StubClient)
    end
  end

  describe "create/2" do
    test "creates a workpad with all standard sections", %{client: pid} do
      assert {:ok, comment_id} = Workpad.create("issue-1", client: StubClient)
      assert is_binary(comment_id)

      [stored] = StubClient.stored_comments(pid, "issue-1")
      assert stored.id == comment_id
      assert stored.body =~ "## Smithy Workpad"
      assert stored.body =~ "### Plan"
      assert stored.body =~ "### Acceptance Criteria"
      assert stored.body =~ "### Validation"
      assert stored.body =~ "### Notes"
      # Confusions is omitted from a fresh workpad until something is confusing.
      refute stored.body =~ "### Confusions"
    end

    test "is idempotent: returns existing comment id without creating a duplicate",
         %{client: pid} do
      assert {:ok, first_id} = Workpad.create("issue-1", client: StubClient)
      assert {:ok, ^first_id} = Workpad.create("issue-1", client: StubClient)

      assert length(StubClient.stored_comments(pid, "issue-1")) == 1
    end

    test "accepts an explicit :body override", %{client: pid} do
      assert {:ok, _id} =
               Workpad.create("issue-1", body: "## Smithy Workpad\n\ncustom\n", client: StubClient)

      [stored] = StubClient.stored_comments(pid, "issue-1")
      assert stored.body == "## Smithy Workpad\n\ncustom\n"
    end
  end

  describe "append_section/4 — existing section" do
    setup %{client: pid} do
      initial_workpad =
        """
        ## Smithy Workpad

        ```text
        host:/tmp/foo@abcd123
        ```

        ### Plan

        - [ ] 1. Parent task

        ### Acceptance Criteria

        - [ ] Criterion 1

        ### Adversarial Review

        #### 2026-05-11 23:47 PASS

        - finding: blah (polish)
        - notes: Ship it.

        ### Notes

        - early note
        """

      Agent.update(pid, fn state ->
        %{
          state
          | comments_by_issue: %{
              "issue-1" => [%{id: "c-existing", body: initial_workpad}]
            }
        }
      end)

      :ok
    end

    test "appends a dated subsection at the end of an existing section", %{client: pid} do
      datetime = ~U[2026-05-12 01:15:00Z]

      assert {:ok, "c-existing"} =
               Workpad.append_section(
                 "issue-1",
                 :adversarial_review,
                 "- finding: dropped a null check (blocker)\n- notes: Send back to builder.",
                 client: StubClient,
                 datetime: datetime,
                 heading: "FAIL (second pass)"
               )

      [stored] = StubClient.stored_comments(pid, "issue-1")
      body = stored.body

      assert body =~ "#### 2026-05-11 23:47 PASS"
      assert body =~ "#### 2026-05-12 01:15 FAIL (second pass)"
      assert body =~ "- finding: dropped a null check (blocker)"
    end

    test "inserts before the next section, not at end of comment", %{client: pid} do
      assert {:ok, _} =
               Workpad.append_section(
                 "issue-1",
                 :adversarial_review,
                 "- inserted entry",
                 client: StubClient,
                 datetime: ~U[2026-05-12 01:15:00Z],
                 heading: "FAIL"
               )

      [stored] = StubClient.stored_comments(pid, "issue-1")
      body = stored.body

      inserted_idx = idx_of(body, "- inserted entry")
      notes_idx = idx_of(body, "### Notes")

      assert inserted_idx < notes_idx, """
      expected the new subsection to land inside ### Adversarial Review,
      before ### Notes. Got body:

      #{body}
      """
    end

    test "preserves earlier subsections in the section", %{client: pid} do
      assert {:ok, _} =
               Workpad.append_section(
                 "issue-1",
                 :adversarial_review,
                 "- second pass notes",
                 client: StubClient,
                 datetime: ~U[2026-05-12 01:15:00Z],
                 heading: "FAIL"
               )

      [stored] = StubClient.stored_comments(pid, "issue-1")
      body = stored.body

      first = idx_of(body, "#### 2026-05-11 23:47 PASS")
      second = idx_of(body, "#### 2026-05-12 01:15 FAIL")

      assert first < second
      assert body =~ "- notes: Ship it."
      assert body =~ "- second pass notes"
    end
  end

  describe "append_section/4 — missing section" do
    setup %{client: pid} do
      initial_workpad =
        """
        ## Smithy Workpad

        ```text
        host:/tmp/foo@abcd123
        ```

        ### Plan

        - [ ] 1. Parent task

        ### Acceptance Criteria

        - [ ] Criterion 1

        ### Validation

        - [ ] targeted tests: `mix test`

        ### Notes

        - early note
        """

      Agent.update(pid, fn state ->
        %{
          state
          | comments_by_issue: %{
              "issue-1" => [%{id: "c-existing", body: initial_workpad}]
            }
        }
      end)

      :ok
    end

    test "creates the section header when missing, in canonical order", %{client: pid} do
      # Adversarial Review goes between Notes and Confusions per canonical order.
      # With only Notes present (no Confusions), it should append at end.
      assert {:ok, _} =
               Workpad.append_section(
                 "issue-1",
                 :adversarial_review,
                 "- finding: first pass clean\n- notes: All good.",
                 client: StubClient,
                 datetime: ~U[2026-05-11 23:47:00Z],
                 heading: "PASS"
               )

      [stored] = StubClient.stored_comments(pid, "issue-1")
      body = stored.body

      assert body =~ "### Adversarial Review"
      assert body =~ "#### 2026-05-11 23:47 PASS"

      # Adversarial Review section header should come after Notes (canonical
      # order with later-section absent means append at end).
      notes_idx = idx_of(body, "### Notes")
      adv_idx = idx_of(body, "### Adversarial Review")
      assert notes_idx < adv_idx
    end

    test "inserts before later canonical sections that already exist", %{client: pid} do
      # Pre-seed a comment that has Confusions but NOT Adversarial Review.
      # The new Adversarial Review section should land between Notes and
      # Confusions per @canonical_section_order.
      body_with_confusions =
        """
        ## Smithy Workpad

        ### Plan

        - [ ] 1. Parent task

        ### Notes

        - n1

        ### Confusions

        - thing X was unclear
        """

      Agent.update(pid, fn state ->
        %{
          state
          | comments_by_issue: %{
              "issue-2" => [%{id: "c-2", body: body_with_confusions}]
            }
        }
      end)

      assert {:ok, _} =
               Workpad.append_section(
                 "issue-2",
                 :adversarial_review,
                 "- finding: ok",
                 client: StubClient,
                 datetime: ~U[2026-05-12 02:00:00Z],
                 heading: "PASS"
               )

      [stored] = StubClient.stored_comments(pid, "issue-2")
      body = stored.body

      notes_idx = idx_of(body, "### Notes")
      adv_idx = idx_of(body, "### Adversarial Review")
      confusions_idx = idx_of(body, "### Confusions")

      assert notes_idx < adv_idx
      assert adv_idx < confusions_idx
    end
  end

  describe "append_section/4 — auto-creates workpad" do
    test "creates a new workpad comment when none exists, then appends", %{client: pid} do
      assert {:ok, comment_id} =
               Workpad.append_section(
                 "issue-3",
                 :adversarial_review,
                 "- finding: first pass clean",
                 client: StubClient,
                 datetime: ~U[2026-05-12 03:00:00Z],
                 heading: "PASS"
               )

      [stored] = StubClient.stored_comments(pid, "issue-3")
      assert stored.id == comment_id
      assert stored.body =~ "## Smithy Workpad"
      assert stored.body =~ "### Adversarial Review"
      assert stored.body =~ "#### 2026-05-12 03:00 PASS"
    end
  end

  describe "append_section/4 — invalid section" do
    test "raises ArgumentError on unknown section", %{client: _pid} do
      assert_raise ArgumentError, ~r/unknown workpad section/, fn ->
        Workpad.append_section("issue-1", :nope, "x", client: StubClient)
      end
    end
  end

  describe "render_template/1" do
    test "produces the canonical workpad template with default placeholders" do
      body = Workpad.render_template(%{})

      assert body =~ "## Smithy Workpad"
      assert body =~ "```text\n<repo-slug>:workspaces/<ticket-id>@<short-sha>\n```"
      assert body =~ "### Plan"
      assert body =~ "- [ ] 1. Parent task"
      assert body =~ "### Acceptance Criteria"
      assert body =~ "- [ ] Criterion 1"
      assert body =~ "### Validation"
      assert body =~ "- [ ] targeted tests: `<command>`"
      assert body =~ "### Notes"
      # Confusions omitted when empty (per WORKFLOW.md guidance).
      refute body =~ "### Confusions"
    end

    test "honors provided vars" do
      body =
        Workpad.render_template(%{
          identity: "claw-01:/repos/smithy@abc1234",
          plan_items: ["1. extract module", "2. write tests"],
          acceptance_criteria: ["module compiles", "tests pass"],
          validation_items: ["mix test test/symphony_elixir/workpad_test.exs"],
          notes: ["session-start: branch spike/foo"]
        })

      assert body =~ "claw-01:/repos/smithy@abc1234"
      assert body =~ "- [ ] 1. extract module"
      assert body =~ "- [ ] 2. write tests"
      assert body =~ "- [ ] module compiles"
      assert body =~ "- [ ] mix test test/symphony_elixir/workpad_test.exs"
      assert body =~ "- session-start: branch spike/foo"
    end

    test "includes ### Confusions when confusions list is non-empty" do
      body = Workpad.render_template(%{confusions: ["Test fixture path ambiguous"]})

      assert body =~ "### Confusions"
      assert body =~ "- Test fixture path ambiguous"
    end

    test "accepts string keys" do
      body = Workpad.render_template(%{"identity" => "x:/p@s", "plan_items" => ["one"]})
      assert body =~ "x:/p@s"
      assert body =~ "- [ ] one"
    end
  end

  defp idx_of(body, needle) do
    case :binary.match(body, needle) do
      {idx, _len} -> idx
      :nomatch -> raise "needle not found in body: #{inspect(needle)}\n\nbody:\n#{body}"
    end
  end
end
