defmodule SymphonyElixir.Runtime do
  @moduledoc """
  Behaviour for agent runtime adapters. Each runtime (Codex, ClaudeCode, future)
  implements this contract so mode dispatch can be runtime-agnostic.

  ## Lifecycle

      {:ok, session} = MyRuntime.start_session(workspace, opts)
      {:ok, result} = MyRuntime.run_turn(session, prompt, issue, opts)
      :ok = MyRuntime.stop_session(session)

  ## Event handling

  Adapters emit normalized event tuples through the `on_message` callback
  provided in `run_turn` opts. Common event shapes:

    * `{:session_started, %{session_id: ...}}`
    * `{:assistant_message, %{text: ..., usage: ...}}`
    * `{:stream_delta, "partial text"}`
    * `{:rate_limit, info_map}`
    * `{:result, %{status: :ok | :error, total_cost_usd: ..., errors: [...]}}`

  Each adapter is free to emit runtime-specific events too, but the above are
  the lingua franca that mode handlers can pattern-match on.
  """

  @typedoc "Adapter-opaque session handle returned by `start_session/2`."
  @type session :: term()

  @typedoc "Keyword options. Each adapter documents its own keys."
  @type opts :: keyword()

  @typedoc "Linear-shaped issue map passed through to the adapter for context."
  @type issue :: map()

  @callback start_session(workspace :: Path.t(), opts()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue(), opts()) ::
              {:ok, map()} | {:error, term()}

  @callback stop_session(session()) :: :ok

  @doc """
  Resolve a runtime atom (`:codex` or `:claude_code`) to the implementing module.
  Used by `AgentRunner` to dispatch on workflow config.

  Resolution is done via `Module.concat/1` so the target adapter does not need
  to be compiled at the time this module loads. Raises `FunctionClauseError`
  for unknown runtime atoms.
  """
  @spec adapter_for(atom()) :: module()
  def adapter_for(:codex), do: Module.concat(SymphonyElixir.Codex, AppServer)

  def adapter_for(:claude_code),
    do: Module.concat([SymphonyElixir.Runtime.ClaudeCode, AppServer])

  @doc """
  Lists supported runtime atoms.
  """
  @spec supported_runtimes() :: [atom()]
  def supported_runtimes, do: [:codex, :claude_code]
end
