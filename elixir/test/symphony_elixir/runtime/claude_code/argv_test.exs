defmodule SymphonyElixir.Runtime.ClaudeCode.ArgvTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Runtime.ClaudeCode.Argv

  describe "build/2 defaults" do
    test "always includes --setting-sources project,local (PER-44)" do
      args = Argv.build("/usr/local/bin/claude")
      assert flag_value(args, "--setting-sources") == "project,local"
    end

    test "always passes --dangerously-skip-permissions (workspace is sandboxed)" do
      args = Argv.build("/usr/local/bin/claude")
      assert "--dangerously-skip-permissions" in args
    end

    test "defaults model to sonnet tier" do
      args = Argv.build("/usr/local/bin/claude")
      assert flag_value(args, "--model") == "claude-sonnet-4-6"
    end

    test "passes -p for print/non-interactive mode" do
      args = Argv.build("/usr/local/bin/claude")
      assert "-p" in args
    end

    test "passes stream-json output format with verbose" do
      args = Argv.build("/usr/local/bin/claude")
      assert flag_value(args, "--output-format") == "stream-json"
      assert "--verbose" in args
    end

    test "includes default disallowed Linear write tools" do
      args = Argv.build("/usr/local/bin/claude")
      val = flag_value(args, "--disallowedTools")

      for tool <- Argv.default_disallowed_tools() do
        assert val =~ tool, "expected #{tool} in --disallowedTools, got #{val}"
      end
    end

    test "does not include --continue when no session_id" do
      args = Argv.build("/usr/local/bin/claude")
      refute "--continue" in args
    end

    test "does not include --max-budget-usd by default" do
      args = Argv.build("/usr/local/bin/claude")
      refute "--max-budget-usd" in args
    end

    test "does not include --append-system-prompt by default" do
      args = Argv.build("/usr/local/bin/claude")
      refute "--append-system-prompt" in args
    end

    test "does not include --add-dir by default" do
      args = Argv.build("/usr/local/bin/claude")
      refute "--add-dir" in args
    end

    test "never includes --bare (would drop OAuth, wrong knob)" do
      args = Argv.build("/usr/local/bin/claude")
      refute "--bare" in args
    end
  end

  describe "build/2 tier selection" do
    test "opus tier maps to claude-opus-4-7" do
      args = Argv.build("/usr/local/bin/claude", tier: :opus)
      assert flag_value(args, "--model") == "claude-opus-4-7"
    end

    test "sonnet tier maps to claude-sonnet-4-6" do
      args = Argv.build("/usr/local/bin/claude", tier: :sonnet)
      assert flag_value(args, "--model") == "claude-sonnet-4-6"
    end

    test "haiku tier maps to claude-haiku-4-5" do
      args = Argv.build("/usr/local/bin/claude", tier: :haiku)
      assert flag_value(args, "--model") == "claude-haiku-4-5"
    end

    test "model_for_tier/1 exposed for callers" do
      assert Argv.model_for_tier(:opus) == "claude-opus-4-7"
      assert Argv.model_for_tier(:sonnet) == "claude-sonnet-4-6"
      assert Argv.model_for_tier(:haiku) == "claude-haiku-4-5"
    end
  end

  describe "build/2 disallowed tools override" do
    test "operator can replace the default deny list" do
      args =
        Argv.build("/usr/local/bin/claude",
          disallowed_tools: ["mcp__custom__write", "mcp__custom__delete"]
        )

      val = flag_value(args, "--disallowedTools")
      assert val == "mcp__custom__write mcp__custom__delete"
    end

    test "empty list is honored (operator explicitly opts out of denials)" do
      args = Argv.build("/usr/local/bin/claude", disallowed_tools: [])
      val = flag_value(args, "--disallowedTools")
      assert val == ""
    end
  end

  describe "build/2 session continuation" do
    test "appends --continue when session_id present" do
      args =
        Argv.build("/usr/local/bin/claude",
          session_id: "33311971-0865-4303-b1a4-24427a1dde3d"
        )

      assert flag_value(args, "--continue") == "33311971-0865-4303-b1a4-24427a1dde3d"
    end
  end

  describe "build/2 cost cap" do
    test "passes --max-budget-usd when set" do
      args = Argv.build("/usr/local/bin/claude", max_budget_usd: 5.00)
      assert flag_value(args, "--max-budget-usd") == "5.0"
    end

    test "accepts integer budget" do
      args = Argv.build("/usr/local/bin/claude", max_budget_usd: 10)
      assert flag_value(args, "--max-budget-usd") == "10"
    end
  end

  describe "build/2 mcp config" do
    test "does not include --mcp-config by default" do
      args = Argv.build("/usr/local/bin/claude")
      refute "--mcp-config" in args
      refute "--strict-mcp-config" in args
    end

    test "appends --mcp-config when path provided" do
      args =
        Argv.build("/usr/local/bin/claude",
          mcp_config: "/tmp/bundle.json"
        )

      assert flag_value(args, "--mcp-config") == "/tmp/bundle.json"
      refute "--strict-mcp-config" in args
    end

    test "appends --strict-mcp-config and --mcp-config when strict and path provided" do
      args =
        Argv.build("/usr/local/bin/claude",
          mcp_config: "/tmp/bundle.json",
          strict_mcp_config: true
        )

      assert "--strict-mcp-config" in args
      assert flag_value(args, "--mcp-config") == "/tmp/bundle.json"
    end

    test "ignores strict_mcp_config when no path is provided" do
      args = Argv.build("/usr/local/bin/claude", strict_mcp_config: true)
      refute "--strict-mcp-config" in args
      refute "--mcp-config" in args
    end
  end

  describe "build/2 system prompt and add-dirs" do
    test "appends --append-system-prompt when set" do
      args =
        Argv.build("/usr/local/bin/claude",
          append_system_prompt: "You are a reviewer."
        )

      assert flag_value(args, "--append-system-prompt") == "You are a reviewer."
    end

    test "appends --add-dir for each extra dir" do
      args =
        Argv.build("/usr/local/bin/claude",
          add_dirs: ["/path/one", "/path/two"]
        )

      pos = Enum.find_index(args, &(&1 == "--add-dir"))
      assert pos != nil
      after_flag = Enum.drop(args, pos + 1)
      assert "/path/one" in after_flag
      assert "/path/two" in after_flag
    end
  end

  describe "build/2 returns valid argv shape" do
    test "all elements are strings" do
      args =
        Argv.build("/usr/local/bin/claude",
          tier: :opus,
          session_id: "abc",
          max_budget_usd: 1.5,
          append_system_prompt: "be terse",
          add_dirs: ["/extra"]
        )

      assert Enum.all?(args, &is_binary/1)
    end

    test "no nil values leak into argv" do
      args = Argv.build("/usr/local/bin/claude")
      refute Enum.any?(args, &is_nil/1)
    end
  end

  # ----- helpers -----

  defp flag_value(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      idx -> Enum.at(args, idx + 1)
    end
  end
end
