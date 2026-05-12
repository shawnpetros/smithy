defmodule SymphonyElixir.Handoff.ReviewTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Handoff.Review

  @fixture_pass_clean "test/support/fixtures/review_pass_clean.md"

  describe "parse/1 valid pass" do
    test "pass with empty findings list" do
      content = """
      ---
      status: pass
      findings: []
      notes: ship it
      ---
      """

      assert {:ok, %Review{status: :pass, findings: [], notes: "ship it"}} =
               Review.parse(content)
    end

    test "pass with omitted findings key defaults to empty" do
      content = """
      ---
      status: pass
      ---
      """

      assert {:ok, %Review{status: :pass, findings: [], notes: nil}} = Review.parse(content)
    end

    test "pass with polish and future advisory findings" do
      content = """
      ---
      status: pass
      findings:
        - finding: rename helper
          grade: polish
        - finding: add stress test
          grade: future
      notes: clean enough to ship
      ---
      """

      assert {:ok, review} = Review.parse(content)
      assert review.status == :pass
      assert length(review.findings) == 2

      assert [
               %{finding: "rename helper", grade: :polish},
               %{finding: "add stress test", grade: :future}
             ] = review.findings

      assert review.notes == "clean enough to ship"
    end
  end

  describe "parse/1 valid fail" do
    test "fail with at least one blocker finding" do
      content = """
      ---
      status: fail
      findings:
        - finding: parser panics on empty input
          grade: blocker
        - finding: nit on naming
          grade: polish
      notes: send back
      ---
      """

      assert {:ok, review} = Review.parse(content)
      assert review.status == :fail
      assert length(review.findings) == 2
      assert hd(review.findings).grade == :blocker
      assert review.notes == "send back"
    end

    test "fail with multiple blockers passes invariant" do
      content = """
      ---
      status: fail
      findings:
        - finding: first blocker
          grade: blocker
        - finding: second blocker
          grade: blocker
      ---
      """

      assert {:ok, review} = Review.parse(content)
      assert review.status == :fail
      assert Enum.all?(review.findings, fn f -> f.grade == :blocker end)
    end
  end

  describe "parse/1 malformed" do
    test "missing frontmatter is rejected" do
      assert {:error, reason} = Review.parse("just some markdown\n")
      assert reason =~ "malformed_frontmatter"
    end

    test "missing closing fence is rejected" do
      content = """
      ---
      status: pass
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "malformed_frontmatter"
      assert reason =~ "closing"
    end

    test "empty document is rejected" do
      assert {:error, reason} = Review.parse("")
      assert reason =~ "malformed_frontmatter"
    end

    test "missing status field is rejected" do
      content = """
      ---
      findings: []
      ---
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "missing_status"
    end

    test "unknown status value is rejected" do
      content = """
      ---
      status: maybe
      ---
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "invalid_status"
      assert reason =~ "maybe"
    end

    test "unknown grade value is rejected" do
      content = """
      ---
      status: fail
      findings:
        - finding: x
          grade: spicy
      ---
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "unknown_grade"
      assert reason =~ "spicy"
    end

    test "missing grade key in a finding is rejected" do
      content = """
      ---
      status: fail
      findings:
        - finding: y
      ---
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "invalid_finding"
      assert reason =~ "grade"
    end

    test "missing finding key is rejected" do
      content = """
      ---
      status: fail
      findings:
        - grade: blocker
      ---
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "invalid_finding"
      assert reason =~ "finding"
    end

    test "fail without any blocker is rejected" do
      content = """
      ---
      status: fail
      findings:
        - finding: x
          grade: polish
      ---
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "fail_without_blocker"
      assert reason =~ "blocker"
    end

    test "fail with only future-grade findings is rejected" do
      content = """
      ---
      status: fail
      findings:
        - finding: tech debt
          grade: future
      ---
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "fail_without_blocker"
    end

    test "fail with empty findings is rejected" do
      content = """
      ---
      status: fail
      findings: []
      ---
      """

      assert {:error, reason} = Review.parse(content)
      assert reason =~ "fail_without_blocker"
    end
  end

  describe "parse/1 notes handling" do
    test "preserves literal block scalar across multiple lines" do
      content = """
      ---
      status: pass
      findings: []
      notes: |
        First line of notes.
        Second line of notes.

        Paragraph after a blank line.
      ---
      """

      assert {:ok, %Review{notes: notes}} = Review.parse(content)
      assert notes =~ "First line of notes."
      assert notes =~ "Second line of notes."
      assert notes =~ "Paragraph after a blank line."
      # interior blank line preserved
      assert notes =~ "\n\n"
    end

    test "missing notes returns nil" do
      content = """
      ---
      status: pass
      findings: []
      ---
      """

      assert {:ok, %Review{notes: nil}} = Review.parse(content)
    end

    test "empty notes string returns nil" do
      content = """
      ---
      status: pass
      findings: []
      notes: ""
      ---
      """

      assert {:ok, %Review{notes: nil}} = Review.parse(content)
    end
  end

  describe "parse/1 case and whitespace tolerance" do
    test "uppercase status is normalized" do
      content = """
      ---
      status: PASS
      findings: []
      ---
      """

      assert {:ok, %Review{status: :pass}} = Review.parse(content)
    end

    test "mixed-case grade is normalized" do
      content = """
      ---
      status: pass
      findings:
        - finding: x
          grade: Polish
      ---
      """

      assert {:ok, %Review{findings: [%{grade: :polish}]}} = Review.parse(content)
    end

    test "leading blank lines before frontmatter are tolerated" do
      content = "\n\n---\nstatus: pass\nfindings: []\n---\n"
      assert {:ok, %Review{status: :pass}} = Review.parse(content)
    end

    test "trailing markdown body after frontmatter is ignored" do
      content = """
      ---
      status: pass
      findings: []
      ---

      # Human-readable body

      Anything down here is ignored by the parser.
      """

      assert {:ok, %Review{status: :pass, findings: []}} = Review.parse(content)
    end
  end

  describe "parse_file/1" do
    test "parses the bundled clean-pass fixture end-to-end" do
      assert {:ok, review} = Review.parse_file(@fixture_pass_clean)
      assert review.status == :pass
      assert review.findings == []
      assert is_binary(review.notes)
      assert review.notes =~ "Diff matches the issue description"
      assert review.notes =~ "Ship it."
    end

    test "returns error tuple for missing file" do
      assert {:error, reason} = Review.parse_file("test/support/fixtures/does_not_exist.md")
      assert reason =~ "read REVIEW.md"
    end
  end
end
