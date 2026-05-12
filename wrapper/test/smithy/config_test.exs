defmodule Smithy.ConfigTest do
  use ExUnit.Case, async: true

  alias Smithy.Config
  alias Smithy.Commands.{AddRepo, RemoveRepo}

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

    test "round-trips scalar extras" do
      body = """
      workspace_root = "~/.smithy/workspaces"
      poll_interval_seconds = 30
      dashboard_enabled = true
      """

      assert {:ok, c} = Config.parse(body)
      rendered = Config.render(c)
      assert {:ok, c2} = Config.parse(rendered)
      assert c2.extras == c.extras
    end

    test "round-trips TOML table extras" do
      body = """
      [repo_paths]
      smithy = "~/projects/smithy"
      substrate = "~/projects/substrate"
      content-pipeline = "~/projects/content-pipeline"
      """

      assert {:ok, c} = Config.parse(body)
      rendered = Config.render(c)

      assert rendered =~ "[repo_paths]"
      assert rendered =~ ~s(smithy = "~/projects/smithy")

      assert {:ok, c2} = Config.parse(rendered)
      assert c2.extras == c.extras
    end

    test "round-trips mixed-type table extras" do
      body = """
      [server]
      port = 80
      host = "localhost"
      enabled = true
      """

      assert {:ok, c} = Config.parse(body)
      rendered = Config.render(c)

      assert rendered =~ "[server]"
      assert rendered =~ "port = 80"
      assert rendered =~ ~s(host = "localhost")
      assert rendered =~ "enabled = true"

      assert {:ok, c2} = Config.parse(rendered)
      assert c2.extras == c.extras
    end

    test "round-trips array-of-table extras" do
      body = """
      [[hooks]]
      name = "preflight"
      enabled = true

      [[hooks]]
      name = "handoff"
      enabled = false
      """

      assert {:ok, c} = Config.parse(body)
      rendered = Config.render(c)

      assert rendered =~ "[[hooks]]"
      assert {:ok, c2} = Config.parse(rendered)
      assert c2.extras == c.extras
    end

    test "round-trips nested table extras" do
      body = """
      [server]
      host = "localhost"

      [server.tls]
      enabled = true
      port = 443
      """

      assert {:ok, c} = Config.parse(body)
      rendered = Config.render(c)

      assert rendered =~ "[server]"
      assert rendered =~ "[server.tls]"

      assert {:ok, c2} = Config.parse(rendered)
      assert c2.extras == c.extras
    end

    test "raises on unsupported extras instead of dropping them" do
      c = %{
        Config.defaults()
        | extras: %{"bad" => [%{"name" => "ok"}, "not-a-table"]}
      }

      assert_raise ArgumentError, ~r/unsupported TOML value at bad/, fn ->
        Config.render(c)
      end
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

    test "add-repo followed by remove-repo preserves legacy config keys" do
      path = tmp_path("legacy.toml")

      File.write!(path, """
      default_runtime = "codex"
      default_workflow = "WORKFLOW.md"
      symphony_binary = "/usr/local/bin/symphony"
      acknowledged_at = "2026-05-12T00:00:00Z"
      linear_teams = ["Personal", "Work"]
      workspace_root = "~/.smithy/workspaces"
      poll_interval_seconds = 30

      [repo_paths]
      smithy = "~/projects/smithy"
      substrate = "~/projects/substrate"
      """)

      deps = %{
        load: fn -> Config.load(path) end,
        write: fn config -> Config.write(config, path) end,
        install: fn _repo, _config -> {:ok, "/tmp/test.plist"} end
      }

      assert {:ok, _} = AddRepo.run(["test", "/tmp/test-repo"], %{}, deps)

      remove_deps = %{
        load: fn -> Config.load(path) end,
        write: fn config -> Config.write(config, path) end,
        unload: fn _slug -> {:ok, ""} end,
        uninstall: fn _slug -> :ok end
      }

      assert {:ok, _} = RemoveRepo.run(["test"], %{}, remove_deps)

      final = File.read!(path)
      assert final =~ ~s(linear_teams = ["Personal", "Work"])
      assert final =~ ~s(workspace_root = "~/.smithy/workspaces")
      assert final =~ "poll_interval_seconds = 30"
      assert final =~ "[repo_paths]"
      refute final =~ "[[repos]]"

      assert {:ok, config} = Config.parse(final)
      assert config.extras["repo_paths"]["smithy"] == "~/projects/smithy"
      assert config.extras["repo_paths"]["substrate"] == "~/projects/substrate"
    end
  end

  defp tmp_path(name) do
    dir =
      Path.join(System.tmp_dir!(), "smithy-config-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    Path.join(dir, name)
  end
end
