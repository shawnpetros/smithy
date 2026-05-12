defmodule SymphonyElixir.Telemetry.EventTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Telemetry.Event

  describe "build/2" do
    test "populates occurred_at with ~now when not provided" do
      before = DateTime.utc_now()
      event = Event.build(:turn_start, ticket: "PER-150")
      after_ = DateTime.utc_now()

      assert event.event == :turn_start
      assert event.ticket == "PER-150"
      assert DateTime.compare(event.occurred_at, before) in [:gt, :eq]
      assert DateTime.compare(event.occurred_at, after_) in [:lt, :eq]
    end

    test "honors an explicit occurred_at" do
      fixed = ~U[2026-01-01 12:00:00Z]
      event = Event.build(:turn_end, occurred_at: fixed, duration_ms: 100)
      assert event.occurred_at == fixed
      assert event.duration_ms == 100
    end

    for kind <- [
          :turn_start,
          :turn_end,
          :session_start,
          :session_end,
          :workspace_created,
          :pr_opened,
          :state_transition,
          :error
        ] do
      test "accepts event kind #{kind}" do
        event = Event.build(unquote(kind), ticket: "PER-1")
        assert event.event == unquote(kind)
        assert %DateTime{} = event.occurred_at
      end
    end

    test "rejects unknown event kinds" do
      assert_raise FunctionClauseError, fn ->
        Event.build(:not_a_real_kind, [])
      end
    end

    test "folds unknown keys into metadata" do
      event = Event.build(:turn_end, ticket: "PER-1", foo: "bar", count: 3)
      assert event.metadata == %{foo: "bar", count: 3}
    end

    test "preserves explicit metadata and merges unknowns over it" do
      event =
        Event.build(:turn_end,
          ticket: "PER-1",
          metadata: %{a: 1, b: 2},
          extra: "z"
        )

      assert event.metadata == %{a: 1, b: 2, extra: "z"}
    end

    test "defaults tools_called to [] and metadata to %{}" do
      event = Event.build(:turn_start, [])
      assert event.tools_called == []
      assert event.metadata == %{}
    end
  end

  describe "to_jsonl_line/1" do
    test "produces a parseable single-line JSON string" do
      event =
        Event.build(:turn_end,
          ticket: "PER-150",
          mode: :builder,
          runtime: :codex,
          duration_ms: 4127,
          outcome: :success,
          input_tokens: 6,
          output_tokens: 25,
          cost_usd: 0.195
        )

      line = Event.to_jsonl_line(event)

      refute String.contains?(line, "\n")
      decoded = Jason.decode!(line)

      assert decoded["event"] == "turn_end"
      assert decoded["mode"] == "builder"
      assert decoded["runtime"] == "codex"
      assert decoded["outcome"] == "success"
      assert decoded["ticket"] == "PER-150"
      assert decoded["duration_ms"] == 4127
      assert decoded["cost_usd"] == 0.195
    end

    test "renders nil scalar fields as JSON null" do
      event = Event.build(:turn_start, ticket: "PER-1")
      line = Event.to_jsonl_line(event)
      decoded = Jason.decode!(line)

      assert decoded["duration_ms"] == nil
      assert decoded["mode"] == nil
      assert decoded["outcome"] == nil
    end

    test "encodes occurred_at as ISO8601" do
      fixed = ~U[2026-05-12 10:30:00Z]
      event = Event.build(:turn_start, ticket: "PER-1", occurred_at: fixed)
      decoded = event |> Event.to_jsonl_line() |> Jason.decode!()

      assert decoded["occurred_at"] == "2026-05-12T10:30:00Z"
    end

    test "round-trips through from_jsonl_line/1" do
      original =
        Event.build(:turn_end,
          ticket: "PER-9",
          mode: :reviewer,
          runtime: :claude_code,
          duration_ms: 871_232,
          outcome: :success,
          input_tokens: 100,
          output_tokens: 200,
          cost_usd: 1.5,
          tools_called: ["Bash", "Read"],
          metadata: %{"session" => "abc"}
        )

      line = Event.to_jsonl_line(original)
      {:ok, decoded} = Event.from_jsonl_line(line)

      assert decoded.event == :turn_end
      assert decoded.ticket == "PER-9"
      assert decoded.mode == :reviewer
      assert decoded.runtime == :claude_code
      assert decoded.duration_ms == 871_232
      assert decoded.outcome == :success
      assert decoded.tools_called == ["Bash", "Read"]
      assert decoded.metadata == %{"session" => "abc"}
      assert DateTime.compare(decoded.occurred_at, original.occurred_at) == :eq
    end
  end

  describe "from_jsonl_line/1" do
    test "returns {:error, _} on malformed JSON" do
      assert {:error, _} = Event.from_jsonl_line("{not json")
    end

    test "tolerates unknown event kind by returning nil event field" do
      line = ~s({"event":"made_up","ticket":"PER-1"})
      {:ok, event} = Event.from_jsonl_line(line)
      assert event.event == nil
      assert event.ticket == "PER-1"
    end
  end
end
