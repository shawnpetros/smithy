defmodule SymphonyElixir.Runtime.ClaudeCode.EventParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Runtime.ClaudeCode.EventParser

  @fixture_minimal "test/support/fixtures/claude_stream_minimal.jsonl"
  @fixture_bare_auth "test/support/fixtures/claude_stream_bare_auth.jsonl"

  describe "parse_line/1 blank and malformed" do
    test "returns nil for empty string" do
      assert EventParser.parse_line("") == nil
    end

    test "returns nil for whitespace-only line" do
      assert EventParser.parse_line("   \t  ") == nil
    end

    test "returns malformed tuple for non-JSON" do
      assert {:malformed, "not json"} = EventParser.parse_line("not json")
    end

    test "returns malformed for partial JSON" do
      assert {:malformed, "{\"type\":"} = EventParser.parse_line("{\"type\":")
    end
  end

  describe "parse_line/1 system events" do
    test "parses system:init with full metadata" do
      line =
        Jason.encode!(%{
          type: "system",
          subtype: "init",
          cwd: "/tmp",
          session_id: "abc-123",
          tools: ["Bash", "Read"],
          model: "claude-opus-4-7",
          permissionMode: "auto",
          claude_code_version: "2.1.139",
          apiKeySource: "none"
        })

      assert {:init, init} = EventParser.parse_line(line)
      assert init.session_id == "abc-123"
      assert init.model == "claude-opus-4-7"
      assert init.cwd == "/tmp"
      assert init.tools == ["Bash", "Read"]
      assert init.permission_mode == "auto"
      assert init.claude_code_version == "2.1.139"
      assert init.api_key_source == "none"
    end

    test "parses system:init with missing tools as empty list" do
      line =
        Jason.encode!(%{
          type: "system",
          subtype: "init",
          session_id: "x"
        })

      assert {:init, init} = EventParser.parse_line(line)
      assert init.tools == []
      assert init.session_id == "x"
      assert init.model == nil
    end

    test "parses hook_started by name" do
      line =
        Jason.encode!(%{
          type: "system",
          subtype: "hook_started",
          hook_name: "SessionStart:startup",
          hook_id: "x"
        })

      assert {:hook_started, "SessionStart:startup"} = EventParser.parse_line(line)
    end

    test "parses hook_response with exit code" do
      line =
        Jason.encode!(%{
          type: "system",
          subtype: "hook_response",
          hook_name: "SessionStart:startup",
          exit_code: 0
        })

      assert {:hook_response, "SessionStart:startup", 0} = EventParser.parse_line(line)
    end

    test "parses hook_response with non-zero exit code" do
      line =
        Jason.encode!(%{
          type: "system",
          subtype: "hook_response",
          hook_name: "Stop:slop-check",
          exit_code: 2
        })

      assert {:hook_response, "Stop:slop-check", 2} = EventParser.parse_line(line)
    end

    test "marks unknown system subtypes as ignored" do
      line = Jason.encode!(%{type: "system", subtype: "future_subtype"})
      assert {:ignored, "system"} = EventParser.parse_line(line)
    end
  end

  describe "parse_line/1 assistant messages" do
    test "joins text blocks into single string" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{
            model: "claude-opus-4-7",
            content: [
              %{type: "text", text: "Hello "},
              %{type: "text", text: "world"}
            ],
            usage: %{input_tokens: 5, output_tokens: 10}
          }
        })

      assert {:assistant_message, msg} = EventParser.parse_line(line)
      assert msg.text == "Hello world"
      assert msg.model == "claude-opus-4-7"
      assert msg.usage["input_tokens"] == 5
      assert msg.usage["output_tokens"] == 10
    end

    test "preserves non-text content blocks (e.g. tool_use)" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{
            content: [
              %{type: "text", text: "I'll call a tool"},
              %{type: "tool_use", id: "tu_1", name: "Bash", input: %{cmd: "ls"}}
            ]
          }
        })

      assert {:assistant_message, msg} = EventParser.parse_line(line)
      assert msg.text == "I'll call a tool"
      assert length(msg.content_blocks) == 2
      assert Enum.at(msg.content_blocks, 1)["type"] == "tool_use"
    end

    test "handles empty content array" do
      line = Jason.encode!(%{type: "assistant", message: %{content: []}})
      assert {:assistant_message, msg} = EventParser.parse_line(line)
      assert msg.text == ""
      assert msg.content_blocks == []
    end

    test "handles missing content field" do
      line = Jason.encode!(%{type: "assistant", message: %{}})
      assert {:assistant_message, msg} = EventParser.parse_line(line)
      assert msg.text == ""
      assert msg.usage == %{}
    end
  end

  describe "parse_line/1 stream events" do
    test "parses content_block_delta as stream_delta" do
      line =
        Jason.encode!(%{
          type: "stream_event",
          event: %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "text_delta", text: "partial"}
          }
        })

      assert {:stream_delta, "partial"} = EventParser.parse_line(line)
    end

    test "parses content_block_start with index" do
      line =
        Jason.encode!(%{
          type: "stream_event",
          event: %{type: "content_block_start", index: 0}
        })

      assert {:stream_block_start, 0} = EventParser.parse_line(line)
    end

    test "parses content_block_stop with index" do
      line =
        Jason.encode!(%{
          type: "stream_event",
          event: %{type: "content_block_stop", index: 0}
        })

      assert {:stream_block_stop, 0} = EventParser.parse_line(line)
    end

    test "ignores unhandled stream sub-events (e.g. message_delta)" do
      line =
        Jason.encode!(%{
          type: "stream_event",
          event: %{type: "message_delta", delta: %{stop_reason: "end_turn"}}
        })

      assert {:ignored, "stream_event"} = EventParser.parse_line(line)
    end
  end

  describe "parse_line/1 rate limit and result" do
    test "parses rate_limit_event with info payload" do
      line =
        Jason.encode!(%{
          type: "rate_limit_event",
          rate_limit_info: %{status: "allowed", resetsAt: 1_778_561_400}
        })

      assert {:rate_limit, info} = EventParser.parse_line(line)
      assert info["status"] == "allowed"
      assert info["resetsAt"] == 1_778_561_400
    end

    test "parses result success" do
      line =
        Jason.encode!(%{
          type: "result",
          subtype: "success",
          is_error: false,
          duration_ms: 100,
          num_turns: 1,
          result: "hello",
          stop_reason: "end_turn",
          total_cost_usd: 0.05,
          modelUsage: %{"claude" => %{costUSD: 0.05}}
        })

      assert {:result, r} = EventParser.parse_line(line)
      assert r.subtype == "success"
      assert r.is_error == false
      assert r.result_text == "hello"
      assert r.total_cost_usd == 0.05
      assert r.duration_ms == 100
      assert r.num_turns == 1
      assert r.model_usage["claude"]["costUSD"] == 0.05
      assert r.errors == []
    end

    test "parses result error_max_budget_usd with errors list" do
      line =
        Jason.encode!(%{
          type: "result",
          subtype: "error_max_budget_usd",
          is_error: true,
          errors: ["Reached maximum budget ($0.05)"]
        })

      assert {:result, r} = EventParser.parse_line(line)
      assert r.subtype == "error_max_budget_usd"
      assert r.is_error == true
      assert r.errors == ["Reached maximum budget ($0.05)"]
      assert r.total_cost_usd == 0
    end

    test "defaults missing fields safely" do
      line = Jason.encode!(%{type: "result"})
      assert {:result, r} = EventParser.parse_line(line)
      assert r.is_error == false
      assert r.duration_ms == 0
      assert r.num_turns == 0
      assert r.total_cost_usd == 0
      assert r.model_usage == %{}
      assert r.errors == []
    end
  end

  describe "parse_line/1 unknown types" do
    test "ignores unknown event types by name" do
      line = Jason.encode!(%{type: "future_unknown_event", payload: %{x: 1}})
      assert {:ignored, "future_unknown_event"} = EventParser.parse_line(line)
    end

    test "ignores JSON without a type field" do
      line = Jason.encode!(%{random: "data"})
      assert {:ignored, "unknown"} = EventParser.parse_line(line)
    end
  end

  describe "parse_stream/1" do
    test "skips blank lines between events" do
      content =
        Enum.join(
          [
            Jason.encode!(%{type: "result", subtype: "success"}),
            "",
            "   ",
            Jason.encode!(%{type: "result", subtype: "success"})
          ],
          "\n"
        )

      events = EventParser.parse_stream(content)
      assert length(events) == 2
    end

    test "handles trailing newline" do
      content = Jason.encode!(%{type: "result", subtype: "success"}) <> "\n"
      assert [{:result, _}] = EventParser.parse_stream(content)
    end

    test "preserves malformed lines mixed with valid ones" do
      content =
        Enum.join(
          [
            Jason.encode!(%{type: "system", subtype: "init", session_id: "x"}),
            "malformed line here",
            Jason.encode!(%{type: "result", subtype: "success"})
          ],
          "\n"
        )

      events = EventParser.parse_stream(content)
      assert length(events) == 3
      assert {:init, _} = Enum.at(events, 0)
      assert {:malformed, "malformed line here"} = Enum.at(events, 1)
      assert {:result, _} = Enum.at(events, 2)
    end
  end

  describe "without_hooks/1" do
    test "filters hook_started and hook_response events" do
      events = [
        {:init, %{session_id: "x"}},
        {:hook_started, "Foo"},
        {:hook_response, "Foo", 0},
        {:assistant_message, %{text: "hi"}},
        {:hook_started, "Bar"},
        {:result, %{subtype: "success"}}
      ]

      filtered = EventParser.without_hooks(events)
      assert length(filtered) == 3
      assert match?({:init, _}, Enum.at(filtered, 0))
      assert match?({:assistant_message, _}, Enum.at(filtered, 1))
      assert match?({:result, _}, Enum.at(filtered, 2))
    end

    test "returns empty list when input is empty" do
      assert EventParser.without_hooks([]) == []
    end

    test "passes through events with no hooks unchanged" do
      events = [{:init, %{}}, {:result, %{}}]
      assert EventParser.without_hooks(events) == events
    end
  end

  describe "real fixture: claude_stream_minimal.jsonl" do
    @describetag :requires_fixture

    test "parses end-to-end without crashing" do
      content = File.read!(@fixture_minimal)
      events = EventParser.parse_stream(content)
      refute Enum.empty?(events)
    end

    test "first non-hook event is :init" do
      content = File.read!(@fixture_minimal)
      events = content |> EventParser.parse_stream() |> EventParser.without_hooks()
      assert {:init, init} = List.first(events)
      assert is_binary(init.session_id)
      assert init.model =~ "claude-opus-4-7"
    end

    test "last event is a :result" do
      content = File.read!(@fixture_minimal)
      events = EventParser.parse_stream(content)
      assert {:result, result} = List.last(events)
      assert result.subtype == "success"
      assert result.is_error == false
      assert result.total_cost_usd > 0
    end

    test "exactly one assistant message present" do
      content = File.read!(@fixture_minimal)
      events = EventParser.parse_stream(content)

      assistants = Enum.filter(events, &match?({:assistant_message, _}, &1))
      assert length(assistants) == 1

      {:assistant_message, msg} = List.first(assistants)
      assert msg.text =~ "smithy spike"
    end

    test "fixture has hook noise that without_hooks strips" do
      content = File.read!(@fixture_minimal)
      events = EventParser.parse_stream(content)
      filtered = EventParser.without_hooks(events)
      assert length(events) > length(filtered),
             "expected hook events in noisy fixture; got 0"
    end
  end

  describe "real fixture: claude_stream_bare_auth.jsonl" do
    @describetag :requires_fixture

    test "auth-failure path still produces parseable result event" do
      content = File.read!(@fixture_bare_auth)
      events = EventParser.parse_stream(content)

      assert {:result, result} = Enum.find(events, &match?({:result, _}, &1))
      assert result.is_error == true
      assert result.result_text =~ "Not logged in"
    end

    test "init event present even on auth failure" do
      content = File.read!(@fixture_bare_auth)
      events = EventParser.parse_stream(content)
      assert Enum.any?(events, &match?({:init, _}, &1))
    end
  end
end
