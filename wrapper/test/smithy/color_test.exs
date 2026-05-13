defmodule Smithy.ColorTest do
  use ExUnit.Case, async: true

  alias Smithy.Color

  describe "slug_hue/1" do
    test "returns value in 0..359 range" do
      for slug <- ["smithy", "substrate", "anvil", "a", "z", "test-repo"] do
        hue = Color.slug_hue(slug)
        assert hue >= 0 and hue <= 359, "#{slug}: expected 0..359, got #{hue}"
      end
    end

    test "is deterministic for the same slug" do
      assert Color.slug_hue("smithy") == Color.slug_hue("smithy")
      assert Color.slug_hue("my-project") == Color.slug_hue("my-project")
    end

    test "different slugs produce different hues (very likely)" do
      hue1 = Color.slug_hue("smithy")
      hue2 = Color.slug_hue("substrate")
      hue3 = Color.slug_hue("anvil")
      assert hue1 != hue2 or hue1 != hue3
    end
  end

  describe "slug_ansi_256/1" do
    test "returns an ANSI escape string" do
      code = Color.slug_ansi_256("smithy")
      assert String.starts_with?(code, "\e[38;5;")
      assert String.ends_with?(code, "m")
    end

    test "embedded color index is in 16..231 (6x6x6 cube)" do
      for slug <- ["smithy", "substrate", "anvil", "x"] do
        code = Color.slug_ansi_256(slug)
        [_, index_str] = Regex.run(~r/\e\[38;5;(\d+)m/, code)
        index = String.to_integer(index_str)
        assert index >= 16 and index <= 231, "#{slug}: expected 16..231, got #{index}"
      end
    end

    test "is deterministic for the same slug" do
      assert Color.slug_ansi_256("smithy") == Color.slug_ansi_256("smithy")
    end
  end

  describe "slug_css_hue/1" do
    test "matches slug_hue/1" do
      for slug <- ["smithy", "substrate", "anvil"] do
        assert Color.slug_css_hue(slug) == Color.slug_hue(slug)
      end
    end
  end
end
