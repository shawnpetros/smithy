defmodule Smithy.SupervisorTest do
  use ExUnit.Case, async: true

  alias Smithy.{Config, Supervisor}

  defp sample_config do
    %{Config.defaults() | symphony_binary: "/usr/local/bin/symphony"}
  end

  defp sample_repo do
    %{
      slug: "smithy",
      path: "/Users/me/projects/smithy",
      workflow: "WORKFLOW.md",
      port: 4001
    }
  end

  describe "label/1" do
    test "builds the launchd label" do
      assert Supervisor.label("smithy") == "com.shawnpetros.smithy.smithy"
    end
  end

  describe "plist_path/1" do
    test "lands under ~/Library/LaunchAgents" do
      assert Supervisor.plist_path("smithy") =~ "/Library/LaunchAgents/com.shawnpetros.smithy.smithy.plist"
    end
  end

  describe "logs_dir/1" do
    test "lands under ~/.smithy/logs/<slug>" do
      assert Supervisor.logs_dir("smithy") =~ "/.smithy/logs/smithy"
    end
  end

  describe "render_plist/2" do
    test "produces a valid plist with the expected keys" do
      xml = Supervisor.render_plist(sample_repo(), sample_config())

      assert xml =~ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      assert xml =~ "<!DOCTYPE plist"
      assert xml =~ "<plist version=\"1.0\">"
      assert xml =~ "<key>Label</key>"
      assert xml =~ "<string>com.shawnpetros.smithy.smithy</string>"
      assert xml =~ "<string>/usr/local/bin/symphony</string>"
      assert xml =~ "<string>--port</string>"
      assert xml =~ "<string>4001</string>"
      assert xml =~ "<string>/Users/me/projects/smithy/WORKFLOW.md</string>"
      assert xml =~ "<key>RunAtLoad</key>"
      assert xml =~ "<true/>"
      assert xml =~ "<key>KeepAlive</key>"
      # SuccessfulExit=false is what makes exit-75 respawn work.
      assert xml =~ "<key>SuccessfulExit</key>\n    <false/>"
      assert xml =~ "stdout.log"
      assert xml =~ "stderr.log"
    end

    test "honors symphony_binary override" do
      cfg = %{sample_config() | symphony_binary: "/opt/smithy/bin/symphony"}
      xml = Supervisor.render_plist(sample_repo(), cfg)
      assert xml =~ "<string>/opt/smithy/bin/symphony</string>"
    end
  end

  describe "load/2 + unload/2" do
    test "passes the right args to the cmd runner" do
      pid = self()

      runner = fn cmd, args ->
        send(pid, {:cmd, cmd, args})
        {"", 0}
      end

      assert {:ok, ""} = Supervisor.load("smithy", runner)
      assert_received {:cmd, "launchctl", ["load", "-w", path]}
      assert path =~ "com.shawnpetros.smithy.smithy.plist"

      assert {:ok, ""} = Supervisor.unload("smithy", runner)
      assert_received {:cmd, "launchctl", ["unload", "-w", _]}
    end

    test "surfaces non-zero exit as an error" do
      runner = fn _cmd, _args -> {"boom", 1} end
      assert {:error, {"boom", 1}} = Supervisor.load("smithy", runner)
    end
  end
end
