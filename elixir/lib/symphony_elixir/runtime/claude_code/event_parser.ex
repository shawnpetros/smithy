defmodule SymphonyElixir.Runtime.ClaudeCode.EventParser do
  @moduledoc """
  Parses Claude Code CLI's `--output-format=stream-json` output into normalized
  event tuples the orchestrator can consume.

  Claude Code emits one JSON object per line (JSONL). This parser:

    * Reads each line and decodes JSON.
    * Classifies the event by its `type` field.
    * Normalizes the most useful fields into typed Elixir maps.
    * Surfaces unknown event types as `{:ignored, type}` so they don't crash
      the consumer if Claude Code adds new event shapes in future versions.
    * Surfaces JSON-decode failures as `{:malformed, original_line}`.

  Pure-function only; no IO, no port management. Process management lives in
  the adapter module that consumes these events from a port.

  ## Event type quick reference

  Output of `claude --print --output-format=stream-json --include-partial-messages`:

    * `system:init` — session metadata (session_id, model, cwd, tools).
    * `system:hook_started` / `system:hook_response` — local hook lifecycle
      (filtered as noise in production runs; Smithy spawns with `--bare`).
    * `assistant` — a full assistant message (after a content block closes).
    * `stream_event[content_block_start|content_block_delta|content_block_stop]` —
      streaming text chunks; only when `--include-partial-messages` is set.
    * `stream_event[message_delta]` — final message metadata; ignored.
    * `rate_limit_event` — rate-limit window status.
    * `result` — terminal event with `subtype: success | error_max_budget_usd | ...`,
      `total_cost_usd`, `modelUsage`, etc.
  """

  @type session_init :: %{
          session_id: String.t() | nil,
          model: String.t() | nil,
          cwd: String.t() | nil,
          tools: [String.t()],
          permission_mode: String.t() | nil,
          claude_code_version: String.t() | nil,
          api_key_source: String.t() | nil
        }

  @type assistant_message :: %{
          text: String.t(),
          content_blocks: [map()],
          model: String.t() | nil,
          usage: map()
        }

  @type result_summary :: %{
          subtype: String.t() | nil,
          is_error: boolean(),
          duration_ms: non_neg_integer(),
          num_turns: non_neg_integer(),
          result_text: String.t() | nil,
          stop_reason: String.t() | nil,
          total_cost_usd: number(),
          model_usage: map(),
          errors: [String.t()]
        }

  @type event ::
          {:init, session_init()}
          | {:hook_started, String.t()}
          | {:hook_response, String.t(), integer()}
          | {:assistant_message, assistant_message()}
          | {:rate_limit, map()}
          | {:stream_delta, String.t()}
          | {:stream_block_start, integer()}
          | {:stream_block_stop, integer()}
          | {:result, result_summary()}
          | {:ignored, String.t()}
          | {:malformed, String.t()}

  @doc """
  Parse a single JSONL line into an event tuple. Returns `nil` for blank lines.
  """
  @spec parse_line(String.t()) :: event() | nil
  def parse_line(line) when is_binary(line) do
    case String.trim(line) do
      "" ->
        nil

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, json} -> classify(json)
          {:error, _} -> {:malformed, trimmed}
        end
    end
  end

  @doc """
  Parse an entire stream (JSONL content) into an ordered list of events.
  Blank lines are skipped.
  """
  @spec parse_stream(String.t()) :: [event()]
  def parse_stream(jsonl_content) when is_binary(jsonl_content) do
    jsonl_content
    |> String.split("\n", trim: false)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Filter hook lifecycle events out of a parsed stream. Hooks are local-machine
  noise (Smithy spawns with `--bare` to skip them, but this helper is useful
  for parsing capture-during-development fixtures or operator-machine reruns).
  """
  @spec without_hooks([event()]) :: [event()]
  def without_hooks(events) when is_list(events) do
    Enum.reject(events, fn
      {:hook_started, _} -> true
      {:hook_response, _, _} -> true
      _ -> false
    end)
  end

  # ----- classification -----

  defp classify(%{"type" => "system", "subtype" => "init"} = json) do
    {:init,
     %{
       session_id: json["session_id"],
       model: json["model"],
       cwd: json["cwd"],
       tools: json["tools"] || [],
       permission_mode: json["permissionMode"],
       claude_code_version: json["claude_code_version"],
       api_key_source: json["apiKeySource"]
     }}
  end

  defp classify(%{"type" => "system", "subtype" => "hook_started", "hook_name" => name}) do
    {:hook_started, name}
  end

  defp classify(%{
         "type" => "system",
         "subtype" => "hook_response",
         "hook_name" => name,
         "exit_code" => exit_code
       }) do
    {:hook_response, name, exit_code}
  end

  defp classify(%{"type" => "system"}) do
    {:ignored, "system"}
  end

  defp classify(%{"type" => "assistant", "message" => message}) do
    blocks = message["content"] || []

    text =
      blocks
      |> Enum.filter(&match?(%{"type" => "text"}, &1))
      |> Enum.map_join("", & &1["text"])

    {:assistant_message,
     %{
       text: text,
       content_blocks: blocks,
       model: message["model"],
       usage: message["usage"] || %{}
     }}
  end

  defp classify(%{"type" => "rate_limit_event", "rate_limit_info" => info}) do
    {:rate_limit, info}
  end

  defp classify(%{
         "type" => "stream_event",
         "event" => %{"type" => "content_block_delta", "delta" => %{"text" => text}}
       }) do
    {:stream_delta, text}
  end

  defp classify(%{
         "type" => "stream_event",
         "event" => %{"type" => "content_block_start", "index" => index}
       }) do
    {:stream_block_start, index}
  end

  defp classify(%{
         "type" => "stream_event",
         "event" => %{"type" => "content_block_stop", "index" => index}
       }) do
    {:stream_block_stop, index}
  end

  defp classify(%{"type" => "stream_event"}) do
    {:ignored, "stream_event"}
  end

  defp classify(%{"type" => "result"} = json) do
    {:result,
     %{
       subtype: json["subtype"],
       is_error: json["is_error"] || false,
       duration_ms: json["duration_ms"] || 0,
       num_turns: json["num_turns"] || 0,
       result_text: json["result"],
       stop_reason: json["stop_reason"],
       total_cost_usd: json["total_cost_usd"] || 0,
       model_usage: json["modelUsage"] || %{},
       errors: json["errors"] || []
     }}
  end

  defp classify(%{"type" => type}), do: {:ignored, type}
  defp classify(_), do: {:ignored, "unknown"}
end
