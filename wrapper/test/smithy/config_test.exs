defmodule Smithy.ConfigTest do
  use ExUnit.Case, async: true

  alias Smithy.Config

  describe "defaults/0" do
    test "ships sensible defaults" do
      c = Config.defaults()
      assert c.default_runtime == "codex"
      assert c.default_workflow == "WORKFLOW.md"
      assert c.symphony_binary == "/usr/local/bin/symphony"
      assert c.repos == []
    end
  end

  describe "parse/1" do
    test "parses an empty body" do
      assert {:ok, c} = Config.parse("")
      assert c.repos == []
    end

    test "parses repos array-of-tables and respects defaults" do
      body = """
      default_runtime = "codex"
      default_workflow = "WORKFLOW.md"
      symphony_binary = "/opt/symphony"

      [[repos]]
      slug = "smithy"
      path = "/Users/me/projects/smithy"
      workflow = "WORKFLOW.md"
      port = 4001

      [[repos]]
      slug = "substrate"
      path = "/Users/me/projects/substrate"
      port = 4002
      """

      assert {:ok, c} = Config.parse(body)
      assert c.symphony_binary == "/opt/symphony"
      assert length(c.repos) == 2
      [r1, r2] = c.repos
      assert r1.slug == "smithy"
      assert r1.port == 4001
      assert r1.workflow == "WORKFLOW.md"
      assert r2.workflow == "WORKFLOW.md"
    end

    test "preserves unknown top-level keys as extras" do
      body = """
      linear_teams = ["Personal", "Work"]
      poll_interval_seconds = 30
      """

      assert {:ok, c} = Config.parse(body)
      assert c.extras["linear_teams"] == ["Personal", "Work"]
      assert c.extras["poll_interval_seconds"] == 30
    end

    test "returns error on garbage TOML" do
      assert {:error, _} = Config.parse("this = is = not = toml")
    end
  end

  describe "render/1" do
    test "round-trips a typical config" do
      body = """
      default_runtime = "codex"
      default_workflow = "WORKFLOW.md"
      symphony_binary = "/usr/local/bin/symphony"

      [[repos]]
      slug = "smithy"
      path = "/Users/me/projects/smithy"
      workflow = "WORKFLOW.md"
      port = 4001
      """

      {:ok, c} = Config.parse(body)
      rendered = Config.render(c)

      assert rendered =~ ~s(default_runtime = "codex")
      assert rendered =~ ~s([[repos]])
      assert rendered =~ ~s(port = 4001)

      {:ok, c2} = Config.parse(rendered)
      assert c2.repos == c.repos
    end

    test "renders string-array extras like linear_teams" do
      c = %{
        Config.defaults()
        | extras: %{"linear_teams" => ["Personal", "Work"], "poll_interval_seconds" => 30}
      }

      rendered = Config.render(c)
      assert rendered =~ ~s(linear_teams = ["Personal", "Work"])
      assert rendered =~ "poll_interval_seconds = 30"
    end
  end

  describe "load/1 + write/2" do
    test "missing file returns defaults" do
      path = tmp_path("missing.toml")
      _ = File.rm(path)
      assert {:ok, c} = Config.load(path)
      assert c == Config.defaults()
    end

    test "writes and reads back" do
      path = tmp_path("roundtrip.toml")
      _ = File.rm(path)
      c = Config.defaults() |> Map.put(:symphony_binary, "/opt/foo")
      assert :ok = Config.write(c, path)
      assert {:ok, c2} = Config.load(path)
      assert c2.symphony_binary == "/opt/foo"
    end
  end

  defp tmp_path(name) do
    dir = Path.join(System.tmp_dir!(), "smithy-config-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Path.join(dir, name)
  end
end
