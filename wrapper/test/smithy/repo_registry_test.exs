defmodule Smithy.RepoRegistryTest do
  use ExUnit.Case, async: true

  alias Smithy.{Config, RepoRegistry}

  describe "add/4" do
    test "auto-assigns port 4001 to the first repo" do
      assert {:ok, {c, repo}} = RepoRegistry.add(Config.defaults(), "smithy", "/tmp/smithy")
      assert repo.port == 4001
      assert repo.workflow == "WORKFLOW.md"
      assert length(c.repos) == 1
    end

    test "auto-assigns 4002, 4003 as more repos are added" do
      c = Config.defaults()
      {:ok, {c, _}} = RepoRegistry.add(c, "a", "/tmp/a")
      {:ok, {c, _}} = RepoRegistry.add(c, "b", "/tmp/b")
      {:ok, {c, r3}} = RepoRegistry.add(c, "c", "/tmp/c")
      assert r3.port == 4003
      assert Enum.map(c.repos, & &1.port) == [4001, 4002, 4003]
    end

    test "respects an explicit port" do
      assert {:ok, {_c, r}} =
               RepoRegistry.add(Config.defaults(), "smithy", "/tmp/smithy", port: 8080)

      assert r.port == 8080
    end

    test "fills holes in the port sequence" do
      {:ok, {c, _}} = RepoRegistry.add(Config.defaults(), "a", "/tmp/a", port: 4001)
      {:ok, {c, _}} = RepoRegistry.add(c, "b", "/tmp/b", port: 4003)
      {:ok, {_c, r}} = RepoRegistry.add(c, "c", "/tmp/c")
      assert r.port == 4002
    end

    test "rejects duplicate slugs" do
      {:ok, {c, _}} = RepoRegistry.add(Config.defaults(), "smithy", "/tmp/a")
      assert {:error, {:duplicate_slug, "smithy"}} = RepoRegistry.add(c, "smithy", "/tmp/b")
    end

    test "rejects duplicate ports" do
      {:ok, {c, _}} = RepoRegistry.add(Config.defaults(), "a", "/tmp/a", port: 4001)
      assert {:error, {:duplicate_port, 4001}} = RepoRegistry.add(c, "b", "/tmp/b", port: 4001)
    end

    test "rejects empty slug" do
      assert {:error, :invalid_slug} = RepoRegistry.add(Config.defaults(), "", "/tmp/a")
    end

    test "honors --workflow override" do
      {:ok, {_c, r}} =
        RepoRegistry.add(Config.defaults(), "x", "/tmp/x", workflow: "custom/PLAN.md")

      assert r.workflow == "custom/PLAN.md"
    end
  end

  describe "remove/2" do
    test "removes a registered repo" do
      {:ok, {c, _}} = RepoRegistry.add(Config.defaults(), "a", "/tmp/a")
      {:ok, {c, _}} = RepoRegistry.add(c, "b", "/tmp/b")
      assert {:ok, {c2, removed}} = RepoRegistry.remove(c, "a")
      assert removed.slug == "a"
      assert Enum.map(c2.repos, & &1.slug) == ["b"]
    end

    test "returns :not_found when slug is missing" do
      assert {:error, :not_found} = RepoRegistry.remove(Config.defaults(), "nope")
    end
  end

  describe "fetch/2 + list/1" do
    test "lists and fetches" do
      {:ok, {c, _}} = RepoRegistry.add(Config.defaults(), "a", "/tmp/a")
      assert [_] = RepoRegistry.list(c)
      assert {:ok, r} = RepoRegistry.fetch(c, "a")
      assert r.slug == "a"
      assert {:error, :not_found} = RepoRegistry.fetch(c, "missing")
    end
  end
end
