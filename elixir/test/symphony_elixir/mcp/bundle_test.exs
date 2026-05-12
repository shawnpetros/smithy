defmodule SymphonyElixir.MCP.BundleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.MCP.Bundle

  describe "load/2 from priv/" do
    test "loads the bundled linear-read bundle" do
      assert {:ok, bundle} = Bundle.load("linear-read")
      assert is_map(bundle)
      assert Map.has_key?(bundle, "linear")
      assert get_in(bundle, ["linear", "command"]) == "npx"
    end

    test "strips top-level _comment keys" do
      assert {:ok, bundle} = Bundle.load("github")
      refute Map.has_key?(bundle, "_comment")
      assert Map.has_key?(bundle, "github")
    end

    test "returns {:error, :not_found} for an unknown name" do
      assert Bundle.load("does-not-exist-12345") == {:error, :not_found}
    end
  end

  describe "load/2 from repo override" do
    setup do
      tmp = tmp_dir!("override")

      File.write!(
        Path.join(tmp, "custom.json"),
        Jason.encode!(%{"custom" => %{"command" => "echo", "args" => ["hi"]}})
      )

      {:ok, repo_dir: tmp}
    end

    test "loads from a repo override directory", %{repo_dir: dir} do
      assert {:ok, bundle} = Bundle.load("custom", repo_paths: [dir])
      assert get_in(bundle, ["custom", "command"]) == "echo"
    end

    test "repo override wins over priv/ when name collides", %{repo_dir: dir} do
      # Shadow the shipped linear-read bundle with a repo-local one.
      File.write!(
        Path.join(dir, "linear-read.json"),
        Jason.encode!(%{"linear" => %{"command" => "OVERRIDDEN", "args" => []}})
      )

      assert {:ok, bundle} = Bundle.load("linear-read", repo_paths: [dir])
      assert get_in(bundle, ["linear", "command"]) == "OVERRIDDEN"
    end

    test "earlier repo_paths win over later", _ do
      dir_a = tmp_dir!("win-a")
      dir_b = tmp_dir!("win-b")

      File.write!(
        Path.join(dir_a, "thing.json"),
        Jason.encode!(%{"thing" => %{"command" => "A"}})
      )

      File.write!(
        Path.join(dir_b, "thing.json"),
        Jason.encode!(%{"thing" => %{"command" => "B"}})
      )

      assert {:ok, bundle} = Bundle.load("thing", repo_paths: [dir_a, dir_b])
      assert get_in(bundle, ["thing", "command"]) == "A"
    end

    test "falls back to priv/ when override directory has no match", %{repo_dir: dir} do
      assert {:ok, bundle} = Bundle.load("linear-read", repo_paths: [dir])
      assert Map.has_key?(bundle, "linear")
    end

    test "returns {:error, {:invalid_json, _}} for malformed JSON in an override", %{
      repo_dir: dir
    } do
      File.write!(Path.join(dir, "broken.json"), "{not json")
      assert {:error, {:invalid_json, _}} = Bundle.load("broken", repo_paths: [dir])
    end
  end

  describe "merge/1" do
    test "returns empty map for empty list" do
      assert Bundle.merge([]) == %{}
    end

    test "merges two bundles with no overlap" do
      a = %{"linear" => %{"command" => "npx"}}
      b = %{"github" => %{"command" => "npx"}}

      merged = Bundle.merge([a, b])
      assert Map.has_key?(merged, "linear")
      assert Map.has_key?(merged, "github")
      assert map_size(merged) == 2
    end

    test "later bundle wins on key collision" do
      a = %{"linear" => %{"command" => "OLD"}}
      b = %{"linear" => %{"command" => "NEW"}}

      assert %{"linear" => %{"command" => "NEW"}} = Bundle.merge([a, b])
    end

    test "merge is left-to-right for three bundles" do
      a = %{"x" => 1, "y" => 1}
      b = %{"y" => 2, "z" => 2}
      c = %{"z" => 3}

      assert %{"x" => 1, "y" => 2, "z" => 3} = Bundle.merge([a, b, c])
    end
  end

  describe "write_config/2" do
    test "writes a valid JSON file wrapped in mcpServers envelope" do
      tmp = tmp_dir!("write")
      dest = Path.join(tmp, "mcp.json")

      bundle = %{"linear" => %{"command" => "npx", "args" => ["-y", "linear-mcp"]}}
      assert {:ok, ^dest} = Bundle.write_config(bundle, dest)

      assert {:ok, raw} = File.read(dest)
      assert {:ok, decoded} = Jason.decode(raw)

      assert %{"mcpServers" => servers} = decoded
      assert get_in(servers, ["linear", "command"]) == "npx"
      assert get_in(servers, ["linear", "args"]) == ["-y", "linear-mcp"]
    end

    test "creates intermediate directories" do
      tmp = tmp_dir!("write-nested")
      dest = Path.join([tmp, "a", "b", "c", "mcp.json"])

      assert {:ok, ^dest} = Bundle.write_config(%{}, dest)
      assert File.regular?(dest)
    end

    test "round-trips an empty bundle" do
      tmp = tmp_dir!("write-empty")
      dest = Path.join(tmp, "mcp.json")

      assert {:ok, ^dest} = Bundle.write_config(%{}, dest)
      assert {:ok, %{"mcpServers" => %{}}} = Jason.decode(File.read!(dest))
    end
  end

  describe "list_available/1" do
    test "returns the shipped library bundles sorted and unique" do
      names = Bundle.list_available()

      assert "linear-read" in names
      assert "github" in names
      assert "playwright" in names
      assert names == Enum.sort(names)
      assert names == Enum.uniq(names)
    end

    test "merges repo override entries with priv/ entries" do
      dir = tmp_dir!("list")
      File.write!(Path.join(dir, "extra.json"), Jason.encode!(%{"extra" => %{}}))

      names = Bundle.list_available(repo_paths: [dir])

      assert "extra" in names
      assert "linear-read" in names
    end

    test "deduplicates when a name appears in both override and priv/" do
      dir = tmp_dir!("list-dedup")
      File.write!(Path.join(dir, "linear-read.json"), Jason.encode!(%{}))

      names = Bundle.list_available(repo_paths: [dir])
      assert Enum.count(names, &(&1 == "linear-read")) == 1
    end

    test "ignores non-json files in override directories" do
      dir = tmp_dir!("list-noise")
      File.write!(Path.join(dir, "README.md"), "ignore me")
      File.write!(Path.join(dir, "good.json"), Jason.encode!(%{}))

      names = Bundle.list_available(repo_paths: [dir])
      assert "good" in names
      refute "README" in names
    end

    test "tolerates a missing override directory" do
      missing = Path.join(System.tmp_dir!(), "smithy-mcp-missing-#{System.unique_integer([:positive])}")
      refute File.exists?(missing)

      names = Bundle.list_available(repo_paths: [missing])
      assert "linear-read" in names
    end
  end

  # --- helpers -------------------------------------------------------------

  defp tmp_dir!(label) do
    path =
      Path.join([
        System.tmp_dir!(),
        "smithy-bundle-test-#{label}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(path)
    on_exit_cleanup(path)
    path
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
  end
end
