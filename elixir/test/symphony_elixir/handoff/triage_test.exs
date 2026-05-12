defmodule SymphonyElixir.Handoff.TriageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Handoff.Triage

  @fixture_flag_underspec "test/support/fixtures/triage_flag_underspec.md"

  describe "parse/1 valid proceed" do
    test "parses proceed with reasons and no gap_comment" do
      content = """
      ---
      decision: proceed
      reasons:
        - "Where: identifies lib/foo/bar.ex"
        - "What: adds X behavior"
        - "Acceptance: asserts new test in test/foo/bar_test.exs"
        - "Ambiguity: none"
      ---
      """

      assert {:ok, %Triage{} = triage} = Triage.parse(content)
      assert triage.decision == :proceed
      assert length(triage.reasons) == 4
      assert hd(triage.reasons) == "Where: identifies lib/foo/bar.ex"
      assert triage.gap_comment == nil
    end

    test "parses proceed with empty reasons (field absent)" do
      content = """
      ---
      decision: proceed
      ---
      """

      assert {:ok, %Triage{decision: :proceed, reasons: [], gap_comment: nil}} =
               Triage.parse(content)
    end

    test "parses proceed with explicit gap_comment (uncommon but valid)" do
      content = """
      ---
      decision: proceed
      reasons:
        - "Trivial typo fix"
      gap_comment: "Operator note: trivial proceed on title alone"
      ---
      """

      assert {:ok, %Triage{decision: :proceed, gap_comment: comment}} = Triage.parse(content)
      assert comment =~ "trivial proceed"
    end

    test "trims whitespace around decision value" do
      content = """
      ---
      decision: "  proceed  "
      ---
      """

      assert {:ok, %Triage{decision: :proceed}} = Triage.parse(content)
    end

    test "ignores body content after the closing fence" do
      content = """
      ---
      decision: proceed
      ---

      Body text here. Should be ignored entirely.

      Even with another --- in it.
      """

      assert {:ok, %Triage{decision: :proceed}} = Triage.parse(content)
    end
  end

  describe "parse/1 valid flag" do
    test "parses flag with reasons and gap_comment" do
      content = """
      ---
      decision: flag
      reasons:
        - "Where: ambiguous"
        - "Acceptance: no testable criterion"
      gap_comment: |
        Multiple gaps detected.
        - Target file is unspecified.
        - No success criterion.
        To re-queue: tighten the ticket and re-add agent-ready.
      ---
      """

      assert {:ok, %Triage{} = triage} = Triage.parse(content)
      assert triage.decision == :flag
      assert length(triage.reasons) == 2
      assert is_binary(triage.gap_comment)
      assert triage.gap_comment =~ "Multiple gaps detected"
      assert triage.gap_comment =~ "To re-queue"
    end
  end

  describe "parse/1 rejections" do
    test "rejects flag with missing gap_comment" do
      content = """
      ---
      decision: flag
      reasons:
        - "Where: ambiguous"
      ---
      """

      assert {:error, :flag_without_gap_comment} = Triage.parse(content)
    end

    test "rejects flag with empty-string gap_comment" do
      content = """
      ---
      decision: flag
      reasons:
        - "Where: ambiguous"
      gap_comment: ""
      ---
      """

      assert {:error, :flag_without_gap_comment} = Triage.parse(content)
    end

    test "rejects flag with whitespace-only gap_comment" do
      content = """
      ---
      decision: flag
      gap_comment: "   \\n\\t  "
      ---
      """

      assert {:error, :flag_without_gap_comment} = Triage.parse(content)
    end

    test "rejects unknown decision value" do
      content = """
      ---
      decision: maybe
      ---
      """

      assert {:error, :invalid_decision} = Triage.parse(content)
    end

    test "rejects decision with wrong type (non-string)" do
      content = """
      ---
      decision: 42
      ---
      """

      assert {:error, :invalid_decision} = Triage.parse(content)
    end

    test "rejects missing decision field" do
      content = """
      ---
      reasons:
        - "Where: identifies lib/foo/bar.ex"
      ---
      """

      assert {:error, :missing_decision} = Triage.parse(content)
    end

    test "rejects empty-string decision" do
      content = """
      ---
      decision: ""
      ---
      """

      assert {:error, :missing_decision} = Triage.parse(content)
    end

    test "rejects content with no front matter at all" do
      content = "just some markdown body, no fence\n"
      assert {:error, :malformed_frontmatter} = Triage.parse(content)
    end

    test "rejects content with opening fence but no closing fence" do
      content = """
      ---
      decision: proceed
      reasons:
        - "Where: identifies lib/foo/bar.ex"
      """

      assert {:error, :malformed_frontmatter} = Triage.parse(content)
    end

    test "rejects empty string" do
      assert {:error, :malformed_frontmatter} = Triage.parse("")
    end

    test "rejects reasons field that is not a list" do
      content = """
      ---
      decision: proceed
      reasons: "Where: lib/foo/bar.ex"
      ---
      """

      assert {:error, {:invalid_reasons, _}} = Triage.parse(content)
    end

    test "rejects reasons list with non-string elements" do
      content = """
      ---
      decision: proceed
      reasons:
        - "Where: identifies lib/foo/bar.ex"
        - 42
      ---
      """

      assert {:error, {:invalid_reasons, _}} = Triage.parse(content)
    end
  end

  describe "parse_file/1" do
    test "reads and parses the underspec'd-ticket flag fixture" do
      assert {:ok, %Triage{} = triage} = Triage.parse_file(@fixture_flag_underspec)
      assert triage.decision == :flag
      assert length(triage.reasons) == 4

      assert Enum.any?(triage.reasons, fn r ->
               String.contains?(r, "Acceptance: no testable criterion")
             end)

      assert is_binary(triage.gap_comment)
      assert triage.gap_comment =~ "cannot be executed autonomously"
      assert triage.gap_comment =~ "To re-queue"
    end

    test "returns posix error tuple for missing file" do
      assert {:error, :enoent} = Triage.parse_file("test/support/fixtures/does_not_exist.md")
    end
  end
end
