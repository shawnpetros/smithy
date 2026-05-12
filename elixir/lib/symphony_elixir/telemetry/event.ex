defmodule SymphonyElixir.Telemetry.Event do
  @moduledoc """
  Telemetry event struct + helpers. Pure functions only.

  Captures wall-clock, token, and cost data at agent invocation boundaries
  so future estimation work has real samples to draw from.
  """

  @type event_kind ::
          :turn_start
          | :turn_end
          | :session_start
          | :session_end
          | :workspace_created
          | :pr_opened
          | :state_transition
          | :error

  @type outcome :: :success | :timeout | :error | :budget_exceeded | nil

  @type t :: %__MODULE__{
          event: event_kind() | nil,
          occurred_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          ticket: String.t() | nil,
          repo_slug: String.t() | nil,
          mode: atom() | nil,
          runtime: atom() | nil,
          persona: String.t() | nil,
          tier: String.t() | nil,
          workspace: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_creation_tokens: non_neg_integer() | nil,
          cost_usd: float() | nil,
          outcome: outcome(),
          error: String.t() | nil,
          run_id: String.t() | nil,
          session_id: String.t() | nil,
          turn_number: non_neg_integer() | nil,
          retry_attempt: non_neg_integer() | nil,
          from_state: String.t() | nil,
          to_state: String.t() | nil,
          tools_called: [String.t()],
          metadata: map()
        }

  defstruct event: nil,
            occurred_at: nil,
            duration_ms: nil,
            ticket: nil,
            repo_slug: nil,
            mode: nil,
            runtime: nil,
            persona: nil,
            tier: nil,
            workspace: nil,
            input_tokens: nil,
            output_tokens: nil,
            cache_read_tokens: nil,
            cache_creation_tokens: nil,
            cost_usd: nil,
            outcome: nil,
            error: nil,
            run_id: nil,
            session_id: nil,
            turn_number: nil,
            retry_attempt: nil,
            from_state: nil,
            to_state: nil,
            tools_called: [],
            metadata: %{}

  @valid_kinds [
    :turn_start,
    :turn_end,
    :session_start,
    :session_end,
    :workspace_created,
    :pr_opened,
    :state_transition,
    :error
  ]

  @struct_keys ~w(
    event occurred_at duration_ms ticket repo_slug mode runtime persona tier
    workspace input_tokens output_tokens cache_read_tokens cache_creation_tokens
    cost_usd outcome error run_id session_id turn_number retry_attempt
    from_state to_state tools_called metadata
  )a

  @doc """
  Build a fully-populated event. Fills `occurred_at` with `DateTime.utc_now/0`
  unless explicitly provided.

  Unknown keys in `opts` are merged into `:metadata`.
  """
  @spec build(event_kind(), keyword()) :: t()
  def build(kind, opts \\ []) when kind in @valid_kinds do
    {known, unknown} = Keyword.split(opts, @struct_keys)

    extra_metadata = Map.new(unknown)

    known_map =
      known
      |> Map.new()
      |> Map.update(:metadata, extra_metadata, fn meta ->
        Map.merge(extra_metadata, meta)
      end)

    base =
      %__MODULE__{}
      |> struct(known_map)
      |> Map.put(:event, kind)

    case base.occurred_at do
      nil -> %{base | occurred_at: DateTime.utc_now()}
      _ -> base
    end
  end

  @doc """
  Serialize to a single JSONL line (no trailing newline).

  Atoms in scalar fields render as strings. The `metadata` map is preserved
  as JSON (atom keys are stringified by Jason).
  """
  @spec to_jsonl_line(t()) :: String.t()
  def to_jsonl_line(%__MODULE__{} = event) do
    event
    |> to_map()
    |> Jason.encode!()
  end

  @doc """
  Inverse of `to_jsonl_line/1`: parse one JSONL line back into an Event.
  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec from_jsonl_line(String.t()) :: {:ok, t()} | {:error, term()}
  def from_jsonl_line(line) when is_binary(line) do
    with {:ok, raw} <- Jason.decode(line) do
      {:ok, from_map(raw)}
    end
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "event" => stringify(event.event),
      "occurred_at" => encode_datetime(event.occurred_at),
      "duration_ms" => event.duration_ms,
      "ticket" => event.ticket,
      "repo_slug" => event.repo_slug,
      "mode" => stringify(event.mode),
      "runtime" => stringify(event.runtime),
      "persona" => event.persona,
      "tier" => event.tier,
      "workspace" => event.workspace,
      "input_tokens" => event.input_tokens,
      "output_tokens" => event.output_tokens,
      "cache_read_tokens" => event.cache_read_tokens,
      "cache_creation_tokens" => event.cache_creation_tokens,
      "cost_usd" => event.cost_usd,
      "outcome" => stringify(event.outcome),
      "error" => event.error,
      "run_id" => event.run_id,
      "session_id" => event.session_id,
      "turn_number" => event.turn_number,
      "retry_attempt" => event.retry_attempt,
      "from_state" => event.from_state,
      "to_state" => event.to_state,
      "tools_called" => event.tools_called || [],
      "metadata" => event.metadata || %{}
    }
  end

  @doc false
  @spec from_map(map()) :: t()
  def from_map(raw) when is_map(raw) do
    %__MODULE__{
      event: atomize_event(raw["event"]),
      occurred_at: decode_datetime(raw["occurred_at"]),
      duration_ms: raw["duration_ms"],
      ticket: raw["ticket"],
      repo_slug: raw["repo_slug"],
      mode: atomize_optional(raw["mode"]),
      runtime: atomize_optional(raw["runtime"]),
      persona: raw["persona"],
      tier: raw["tier"],
      workspace: raw["workspace"],
      input_tokens: raw["input_tokens"],
      output_tokens: raw["output_tokens"],
      cache_read_tokens: raw["cache_read_tokens"],
      cache_creation_tokens: raw["cache_creation_tokens"],
      cost_usd: raw["cost_usd"],
      outcome: atomize_outcome(raw["outcome"]),
      error: raw["error"],
      run_id: raw["run_id"],
      session_id: raw["session_id"],
      turn_number: raw["turn_number"],
      retry_attempt: raw["retry_attempt"],
      from_state: raw["from_state"],
      to_state: raw["to_state"],
      tools_called: raw["tools_called"] || [],
      metadata: raw["metadata"] || %{}
    }
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decode_datetime(nil), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp atomize_event(nil), do: nil

  defp atomize_event(value) when is_binary(value) do
    candidate = safe_to_existing_atom(value)

    if candidate in @valid_kinds do
      candidate
    else
      nil
    end
  end

  defp atomize_outcome(nil), do: nil

  defp atomize_outcome(value) when is_binary(value) do
    case value do
      "success" -> :success
      "timeout" -> :timeout
      "error" -> :error
      "budget_exceeded" -> :budget_exceeded
      _ -> nil
    end
  end

  defp atomize_optional(nil), do: nil

  defp atomize_optional(value) when is_binary(value) do
    safe_to_existing_atom(value)
  end

  defp safe_to_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> String.to_atom(value)
  end
end
