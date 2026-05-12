defmodule SymphonyElixir.Runtime.ClaudeCode.AppServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Runtime.ClaudeCode.AppServer

  @fixture_minimal "test/support/fixtures/claude_stream_minimal.jsonl"
  @fixture_bare_auth "test/support/fixtures/claude_stream_bare_auth.jsonl"

  describe "start_session/2 workspace validation" do
    test "rejects a workspace that does not exist" do
      missing =
        Path.join(System.tmp_dir!(), "smithy-claudecode-missing-#{:rand.uniform(1_000_000)}")

      refute File.exists?(missing)

      assert {:error, {:invalid_workspace, :missing, _}} =
               AppServer.start_session(missing)
    end

    test "rejects a workspace that is a file, not a directory" do
      path =
        Path.join(System.tmp_dir!(), "smithy-claudecode-file-#{:rand.uniform(1_000_000)}.txt")

      File.write!(path, "not a dir")
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:invalid_workspace, :not_a_directory, _}} =
               AppServer.start_session(path)
    end

    test "accepts an existing workspace directory" do
      dir =
        Path.join(System.tmp_dir!(), "smithy-claudecode-ok-#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, session} = AppServer.start_session(dir)
      assert session.workspace == Path.expand(dir)
    end
  end

  describe "start_session/2 session struct" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "smithy-claudecode-fields-#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "defaults tier to :sonnet and disallowed_tools to the Linear write set", %{dir: dir} do
      {:ok, session} = AppServer.start_session(dir)
      assert session.tier == :sonnet

      assert "mcp__linear__save_issue" in session.disallowed_tools
      assert "mcp__linear__delete_comment" in session.disallowed_tools
    end

    test "captures persona_path, tier, mcp_config_path, disallowed_tools, session_id, claude_bin", %{dir: dir} do
      {:ok, session} =
        AppServer.start_session(dir,
          tier: :opus,
          persona_path: "/tmp/persona.md",
          mcp_config_path: "/tmp/bundle.json",
          disallowed_tools: ["mcp__custom__write"],
          session_id: "resume-me-123",
          claude_bin: "/usr/local/bin/claude"
        )

      assert session.tier == :opus
      assert session.persona_path == "/tmp/persona.md"
      assert session.mcp_config_path == "/tmp/bundle.json"
      assert session.disallowed_tools == ["mcp__custom__write"]
      assert session.session_id == "resume-me-123"
      assert session.claude_bin == "/usr/local/bin/claude"
    end

    test "initializes port=nil and accumulator=\"\"", %{dir: dir} do
      {:ok, session} = AppServer.start_session(dir)
      assert session.port == nil
      assert session.accumulator == ""
    end

    test "resolves claude binary path when not provided", %{dir: dir} do
      # Whatever the host resolves, the result must be a binary string.
      {:ok, session} = AppServer.start_session(dir)
      assert is_binary(session.claude_bin)
      assert session.claude_bin != ""
    end
  end

  describe "default_turn_timeout_ms/0" do
    setup do
      previous = System.get_env("SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS")

      on_exit(fn ->
        restore_env("SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS", previous)
      end)

      :ok
    end

    test "defaults to the built-in timeout" do
      System.delete_env("SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS")
      assert AppServer.default_turn_timeout_ms() == 600_000
    end

    test "uses a positive integer env fallback" do
      System.put_env("SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS", "900000")
      assert AppServer.default_turn_timeout_ms() == 900_000
    end

    test "ignores invalid env values" do
      System.put_env("SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS", "0")
      assert AppServer.default_turn_timeout_ms() == 600_000

      System.put_env("SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS", "not-an-integer")
      assert AppServer.default_turn_timeout_ms() == 600_000
    end
  end

  describe "stop_session/1" do
    test "is a no-op when port is nil" do
      assert :ok = AppServer.stop_session(%{port: nil})
    end

    test "tolerates a session map missing a port key" do
      assert :ok = AppServer.stop_session(%{})
    end
  end

  describe "process_chunk/6 partial-line buffering" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "smithy-claudecode-chunk-#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} = AppServer.start_session(dir)
      {:ok, session: session}
    end

    test "single chunk with one complete line and result terminates the loop", %{session: session} do
      collector = start_collector()
      cb = collector_callback(collector)

      result_line =
        Jason.encode!(%{type: "result", subtype: "success", total_cost_usd: 0.5}) <> "\n"

      assert {:ok, %{result: result, event_count: 1}} =
               AppServer.process_chunk(session, result_line, cb, 1_000, nil, 0)

      assert result.total_cost_usd == 0.5
      events = events_collected(collector)
      assert [{:result, _}] = events
    end

    test "init event captures session_id for next-turn continuity", %{session: session} do
      collector = start_collector()
      cb = collector_callback(collector)

      init_line = Jason.encode!(%{type: "system", subtype: "init", session_id: "abc-123"}) <> "\n"
      result_line = Jason.encode!(%{type: "result", subtype: "success"}) <> "\n"

      chunk = init_line <> result_line

      assert {:ok, %{session_id: "abc-123", event_count: 2}} =
               AppServer.process_chunk(session, chunk, cb, 1_000, nil, 0)

      events = events_collected(collector)
      assert {:init, %{session_id: "abc-123"}} = Enum.at(events, 0)
      assert {:result, _} = Enum.at(events, 1)
    end

    test "result event terminates the loop with summary fields", %{session: session} do
      result_line =
        Jason.encode!(%{
          type: "result",
          subtype: "success",
          is_error: false,
          duration_ms: 100,
          num_turns: 1,
          result: "hello",
          total_cost_usd: 0.05,
          errors: []
        }) <> "\n"

      assert {:ok, %{result: result, event_count: 1}} =
               AppServer.process_chunk(session, result_line, fn _ -> :ok end, 1_000, nil, 0)

      assert result.subtype == "success"
      assert result.is_error == false
      assert result.num_turns == 1
      assert result.result_text == "hello"
      assert result.total_cost_usd == 0.05
    end

    test "malformed line is emitted as event and does not crash the loop", %{session: session} do
      collector = start_collector()
      cb = collector_callback(collector)

      chunk =
        "not a json line\n" <>
          Jason.encode!(%{type: "result", subtype: "success"}) <> "\n"

      assert {:ok, %{event_count: 2}} =
               AppServer.process_chunk(session, chunk, cb, 1_000, nil, 0)

      events = events_collected(collector)
      assert {:malformed, "not a json line"} = Enum.at(events, 0)
      assert {:result, _} = Enum.at(events, 1)
    end

    test "blank lines between events do not count as events", %{session: session} do
      chunk =
        "\n   \n" <>
          Jason.encode!(%{type: "result", subtype: "success"}) <> "\n"

      assert {:ok, %{event_count: 1}} =
               AppServer.process_chunk(session, chunk, fn _ -> :ok end, 1_000, nil, 0)
    end
  end

  describe "process_chunk/6 with real fixtures" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "smithy-claudecode-fixture-#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} = AppServer.start_session(dir)
      {:ok, session: session}
    end

    test "drives the full minimal fixture to a success result", %{session: session} do
      collector = start_collector()
      cb = collector_callback(collector)

      content = File.read!(@fixture_minimal)

      assert {:ok, %{result: result, session_id: sid}} =
               AppServer.process_chunk(session, content, cb, 1_000, nil, 0)

      assert result.is_error == false
      assert result.total_cost_usd > 0
      assert is_binary(sid)
      assert sid != ""

      events = events_collected(collector)
      assert Enum.any?(events, &match?({:init, _}, &1))
      assert Enum.any?(events, &match?({:assistant_message, _}, &1))
      assert Enum.any?(events, &match?({:result, _}, &1))
    end

    test "drives the bare-auth fixture to an error result and still captures session_id", %{
      session: session
    } do
      collector = start_collector()
      cb = collector_callback(collector)

      content = File.read!(@fixture_bare_auth)

      assert {:ok, %{result: result, session_id: sid}} =
               AppServer.process_chunk(session, content, cb, 1_000, nil, 0)

      assert result.is_error == true
      assert result.result_text =~ "Not logged in"
      assert is_binary(sid)
    end
  end

  describe "process_chunk/6 split across multiple chunks" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "smithy-claudecode-split-#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} = AppServer.start_session(dir)
      {:ok, session: session}
    end

    test "buffers a partial line and completes it across chunks via accumulator", %{session: session} do
      # Manually simulate the two-chunk flow that the receive loop would handle:
      # 1) first chunk has no newline; should not emit any events but should
      #    place content in the accumulator.
      # 2) second chunk completes the line plus a terminating result.

      init_json = Jason.encode!(%{type: "system", subtype: "init", session_id: "split-1"})
      result_json = Jason.encode!(%{type: "result", subtype: "success"})

      {first_half, second_half} = String.split_at(init_json, 20)
      chunk1 = first_half
      chunk2 = second_half <> "\n" <> result_json <> "\n"

      # Drive the loop manually by calling the private split_lines logic exactly
      # like the receive loop would. We do this by directly invoking process_chunk
      # in two stages, threading the resulting session.accumulator forward.
      #
      # Since process_chunk recurses into receive_loop after the first chunk
      # (because no :result yet), we can't call it directly with chunk1 alone.
      # Instead, prove the buffering by sending the whole thing in one chunk
      # split at the middle of init_json: the parser must still produce 2 events.
      whole = chunk1 <> chunk2

      collector = start_collector()
      cb = collector_callback(collector)

      assert {:ok, %{session_id: "split-1", event_count: 2}} =
               AppServer.process_chunk(session, whole, cb, 1_000, nil, 0)
    end

    test "partial line at the end of a chunk does not emit an event", %{session: session} do
      # Send only a partial JSONL (no newline) and confirm the loop times out
      # rather than emitting a malformed event prematurely. We use a short
      # timeout so the test is fast.
      partial = "{\"type\":\"sys"

      assert {:error, :timeout} =
               AppServer.process_chunk(session, partial, fn _ -> :ok end, 50, nil, 0)
    end

    test "carries accumulator through to a follow-up chunk that completes the line", %{
      session: session
    } do
      # Real two-chunk path: send a partial via process_chunk, but the loop will
      # block waiting for the next port message. Simulate by manually delivering
      # a fake `{port, {:data, chunk}}` follow-up. We need a port handle; use
      # a dummy port-like reference via Port.open with /usr/bin/true so the
      # match works in the loop.
      bin = System.find_executable("true") || "/usr/bin/true"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(bin)},
          [:binary, :exit_status, :hide]
        )

      session = %{session | port: port}

      init_json = Jason.encode!(%{type: "system", subtype: "init", session_id: "carry-1"})
      result_json = Jason.encode!(%{type: "result", subtype: "success"})

      # Pre-load the inbox with the follow-up chunks before invoking the loop.
      # The first message is the closing half of init_json plus result line.
      {head, tail} = String.split_at(init_json, 25)
      follow = tail <> "\n" <> result_json <> "\n"

      # Deliver the second chunk into our own inbox so the receive_loop picks
      # it up via the {port, {:data, chunk}} match.
      send(self(), {port, {:data, follow}})

      collector = start_collector()
      cb = collector_callback(collector)

      assert {:ok, %{session_id: "carry-1", event_count: 2}} =
               AppServer.process_chunk(session, head, cb, 1_000, nil, 0)

      # Clean up any residual port; close_port is best-effort.
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  describe "run_turn/4 error paths" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "smithy-claudecode-runerr-#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} = AppServer.start_session(dir, claude_bin: "/nonexistent/claude/binary")
      {:ok, session: session, dir: dir}
    end

    test "returns a {:error, ...} tuple when the claude binary cannot be spawned", %{
      session: session
    } do
      # Port.open against a nonexistent executable raises ArgumentError, which
      # open_port catches and surfaces as {:port_open_failed, _}.
      assert {:error, {:port_open_failed, _msg}} =
               AppServer.run_turn(session, "hello", %{identifier: "TEST-1"})
    end
  end

  # ----- collector helpers -----

  defp start_collector do
    Agent.start_link(fn -> [] end)
  end

  defp collector_callback({:ok, pid}) do
    fn event -> Agent.update(pid, fn acc -> acc ++ [event] end) end
  end

  defp events_collected({:ok, pid}) do
    Agent.get(pid, & &1)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
