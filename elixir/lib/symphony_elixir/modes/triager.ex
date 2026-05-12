defmodule SymphonyElixir.Modes.Triager do
  @moduledoc """
  Orchestrates a single spec-quality-gate pass on a ticket carrying the
  `agent-ready` label.

  Triager runs front-of-queue, before the builder dispatches, and decides
  whether the ticket is well-specified enough to be executed autonomously.
  It spawns the triager agent via the runtime adapter for
  `agent_config.runtime`, parses the `TRIAGE.md` the agent writes at the
  workspace root, and returns a structured outcome the orchestrator uses
  to transition Linear state and adjust labels.

  Mirrors `SymphonyElixir.Modes.Reviewer` deliberately: same opt shape,
  same persona-resolution rules, same denylist philosophy (Linear writes
  forbidden, Edit/Write kept so the triager can emit TRIAGE.md). No
  Linear writes happen here; the orchestrator owns every state move,
  comment, and label.

  Pre-implementation by design. No diff is fetched.

  ## Outcome contract

    * `{:proceed, %Triage{}}` -> next state `In Progress`, no label change,
      orchestrator dispatches the builder.
    * `{:flag, %Triage{}}`    -> next state `Backlog`, add `needs-spec`,
      remove `agent-ready`, post `gap_comment` to the workpad.
    * `{:blocked, reason}`    -> stays in `Todo`; the orchestrator applies
      `harness-blocked` out-of-band.

  ## Tool denylist

  Triager spawns get a denylist via `:disallowed_tools` so a misbehaving
  triager cannot mutate Linear. Edit/Write stay allowed so the triager
  can produce TRIAGE.md, matching Reviewer's posture. The persona prompt
  constrains usage to "TRIAGE.md only".

  ## Injectable IO

  All IO routes through opts so tests run without forking processes:

    * `:adapter`         - runtime adapter module (defaults to
      `SymphonyElixir.Runtime.adapter_for(agent_config.runtime)`)
    * `:persona_loader`  - `(path -> {:ok, Persona.t()} | {:error, _})`
      (defaults to `Persona.load/1`)
    * `:triage_reader`   - `(path -> {:ok, Triage.t()} | {:error, _})`
      (defaults to `Triage.parse_file/1`)
    * `:project_dir`     - directory to search for repo-local persona
      overrides at `<project_dir>/.smithy/personas/<name>.md` (defaults
      to `File.cwd!/0`)
    * `:mcp_config_path` - path to a pre-rendered `--mcp-config` JSON; if
      absent, the adapter receives `nil` and decides how to handle it
    * `:on_message`      - turn event callback forwarded to the adapter
  """

  require Logger

  alias SymphonyElixir.Handoff.Triage
  alias SymphonyElixir.Modes.{Dispatch, Outcomes}
  alias SymphonyElixir.Personas.Persona
  alias SymphonyElixir.Runtime

  @type issue :: SymphonyElixir.Linear.Issue.t() | map()
  @type agent_config :: SymphonyElixir.Config.Schema.AgentConfig.t()
  @type triage_outcome ::
          {:proceed, Triage.t()}
          | {:flag, Triage.t()}
          | {:blocked, reason :: String.t()}

  @doc false
  @spec run_mode(issue(), agent_config(), keyword(), Dispatch.worker_host()) :: :ok
  def run_mode(issue, agent_config, opts, worker_host) do
    triager_mod = Keyword.get(opts, :triager_mod, __MODULE__)

    Dispatch.run_outcome_mode(
      :triager,
      issue,
      agent_config,
      opts,
      worker_host,
      triager_mod,
      &Outcomes.handle_triager_outcome/3,
      &turn_outcome/1
    )
  end

  # Same posture as Modes.Reviewer: deny every Linear write tool, keep
  # Write/Edit available because the triager needs to emit TRIAGE.md.
  # Persona prompt constrains the write surface. Future hardening
  # (pre-seed sentinel TRIAGE.md + restrict to Edit) tracked alongside
  # the reviewer counterpart.
  @triager_disallowed_tools [
    "mcp__linear__save_issue",
    "mcp__linear__save_comment",
    "mcp__linear__save_document",
    "mcp__linear__save_milestone",
    "mcp__linear__save_project",
    "mcp__linear__delete_comment",
    "mcp__linear__delete_attachment",
    "mcp__linear__create_attachment",
    "mcp__linear__create_issue_label"
  ]

  @personas_subdir "personas"
  @repo_personas_subdir ".smithy/personas"

  @doc """
  Run the triager pass on `issue` within `workspace`.

  The function never raises. Adapter failures bubble back as
  `{:error, term()}`. Persona-load failures also surface as
  `{:error, _}`. Only TRIAGE.md problems convert to
  `{:ok, {:blocked, _}}`, because the triager DID run and the
  orchestrator should record the run before parking the ticket.
  """
  @spec run(issue(), Path.t(), agent_config(), keyword()) ::
          {:ok, triage_outcome()} | {:error, term()}
  def run(issue, workspace, agent_config, opts \\ []) do
    with {:ok, persona_path} <- resolve_persona_path(agent_config, opts),
         {:ok, persona} <- load_persona(persona_path, opts),
         rendered = render_prompt(persona, issue, workspace),
         {:ok, _result} <-
           spawn_triager(workspace, agent_config, persona_path, rendered, issue, opts) do
      classify_triage(workspace, opts)
    end
  end

  defp turn_outcome({:proceed, _}), do: :success
  defp turn_outcome({:flag, _}), do: :success
  defp turn_outcome({:blocked, _}), do: :error
  defp turn_outcome(_), do: :error

  @doc """
  Map the triager's outcome to the next Linear state name.

  Per v2/SPEC.md "State machine":

    * proceed  -> "In Progress" (orchestrator dispatches builder next)
    * flag     -> "Backlog" (orchestrator removes `agent-ready`, adds
      `needs-spec`, posts `gap_comment` to the workpad)
    * blocked  -> "Todo" (no transition; orchestrator attaches
      `harness-blocked` label out-of-band)
  """
  @spec next_state(triage_outcome()) :: String.t()
  def next_state({:proceed, _triage}), do: "In Progress"
  def next_state({:flag, _triage}), do: "Backlog"
  def next_state({:blocked, _reason}), do: "Todo"

  @doc """
  Map the triager's outcome to the label action the orchestrator should
  apply on the ticket.

    * `{:proceed, _}` -> `:none` (agent-ready stays as-is)
    * `{:flag, _}`    -> `{:both, %{add: ["needs-spec"],
                                    remove: ["agent-ready"]}}`
    * `{:blocked, _}` -> `{:add, ["harness-blocked"]}`
  """
  @spec label_action(triage_outcome()) ::
          {:add, [String.t()]}
          | {:remove, [String.t()]}
          | :none
          | {:both, %{add: [String.t()], remove: [String.t()]}}
  def label_action({:proceed, _triage}), do: :none

  def label_action({:flag, _triage}) do
    {:both, %{add: ["needs-spec"], remove: ["agent-ready"]}}
  end

  def label_action({:blocked, _reason}), do: {:add, ["harness-blocked"]}

  @doc """
  Return the workpad comment the orchestrator should post for FLAG
  outcomes, the harness-blocked reason for BLOCKED outcomes, or `nil`
  for PROCEED.
  """
  @spec workpad_comment(triage_outcome()) :: String.t() | nil
  def workpad_comment({:proceed, _triage}), do: nil
  def workpad_comment({:flag, %Triage{gap_comment: comment}}), do: comment
  def workpad_comment({:flag, %{gap_comment: comment}}), do: comment

  def workpad_comment({:blocked, reason}) when is_binary(reason) do
    "Harness BLOCKED at triage: #{reason}"
  end

  def workpad_comment({:blocked, reason}) do
    "Harness BLOCKED at triage: #{inspect(reason)}"
  end

  @doc """
  The triager-specific tool denylist surfaced for orchestrator logging,
  config inspection, and tests.
  """
  @spec disallowed_tools() :: [String.t()]
  def disallowed_tools, do: @triager_disallowed_tools

  # --- persona resolution --------------------------------------------------

  defp resolve_persona_path(%{persona: nil}, _opts) do
    {:error, :persona_not_configured}
  end

  defp resolve_persona_path(%{persona: name}, opts) when is_binary(name) do
    candidates = persona_candidates(name, opts)

    Enum.find(candidates, &File.regular?/1)
    |> case do
      nil -> {:error, {:persona_not_found, name, candidates}}
      path -> {:ok, path}
    end
  end

  defp persona_candidates(name, opts) do
    filename =
      if String.ends_with?(name, ".md") do
        name
      else
        name <> ".md"
      end

    priv_path = Path.join(persona_priv_dir(), filename)

    case Keyword.get(opts, :project_dir, default_project_dir()) do
      nil ->
        [priv_path]

      project_dir when is_binary(project_dir) ->
        repo_path = Path.join([project_dir, @repo_personas_subdir, filename])
        # Spec says "priv/ first, fall back to repo-local". Honor that order.
        [priv_path, repo_path]
    end
  end

  defp persona_priv_dir do
    case :code.priv_dir(:symphony_elixir) do
      {:error, :bad_name} ->
        Path.join([File.cwd!(), "priv", @personas_subdir])

      priv when is_list(priv) ->
        Path.join(List.to_string(priv), @personas_subdir)
    end
  end

  defp default_project_dir do
    case File.cwd() do
      {:ok, dir} -> dir
      {:error, _} -> nil
    end
  end

  defp load_persona(path, opts) do
    loader = Keyword.get(opts, :persona_loader, &Persona.load/1)

    case loader.(path) do
      {:ok, %Persona{} = persona} -> {:ok, persona}
      {:ok, other} -> {:error, {:invalid_persona, other}}
      {:error, reason} -> {:error, {:persona_load_failed, reason}}
    end
  end

  # --- prompt rendering ----------------------------------------------------

  defp render_prompt(persona, issue, workspace) do
    vars = %{
      "identifier" => string_field(issue, :identifier),
      "title" => string_field(issue, :title),
      "description" => string_field(issue, :description),
      "labels" => labels_field(issue),
      "branch" => string_field(issue, :branch_name),
      "workspace_path" => to_string(workspace)
    }

    Persona.render(persona, vars)
  end

  defp string_field(nil, _key), do: ""

  defp string_field(issue, key) when is_map(issue) do
    issue
    |> Map.get(key, Map.get(issue, to_string(key)))
    |> case do
      nil -> ""
      value when is_binary(value) -> value
      other -> to_string(other)
    end
  end

  defp labels_field(nil), do: ""

  defp labels_field(issue) when is_map(issue) do
    raw = Map.get(issue, :labels, Map.get(issue, "labels"))

    case raw do
      nil ->
        ""

      list when is_list(list) ->
        list
        |> Enum.map(&label_to_string/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(", ")

      other when is_binary(other) ->
        other

      _ ->
        ""
    end
  end

  defp label_to_string(value) when is_binary(value), do: value
  defp label_to_string(%{name: name}) when is_binary(name), do: name
  defp label_to_string(%{"name" => name}) when is_binary(name), do: name
  defp label_to_string(other) when is_atom(other) and not is_nil(other), do: Atom.to_string(other)
  defp label_to_string(_), do: ""

  # --- adapter spawn -------------------------------------------------------

  defp spawn_triager(workspace, agent_config, persona_path, rendered, issue, opts) do
    adapter = resolve_adapter(agent_config, opts)
    on_message = Keyword.get(opts, :on_message, &noop_on_message/1)

    session_opts =
      [
        persona_path: persona_path,
        tier: agent_config.tier,
        disallowed_tools: @triager_disallowed_tools,
        mcp_config_path: Keyword.get(opts, :mcp_config_path),
        mode: :triager,
        worker_host: Keyword.get(opts, :worker_host)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    turn_opts = [on_message: on_message]

    case adapter.start_session(workspace, session_opts) do
      {:ok, session} ->
        try do
          adapter.run_turn(session, rendered, issue, turn_opts)
        after
          _ = adapter.stop_session(session)
        end

      {:error, _} = err ->
        err
    end
  end

  defp resolve_adapter(%{runtime: runtime}, opts) do
    case Keyword.get(opts, :adapter) do
      nil -> Runtime.adapter_for(runtime)
      mod when is_atom(mod) -> mod
    end
  end

  defp noop_on_message(_event), do: :ok

  # --- TRIAGE.md classification -------------------------------------------

  defp classify_triage(workspace, opts) do
    reader = Keyword.get(opts, :triage_reader, &Triage.parse_file/1)
    path = Path.join(workspace, "TRIAGE.md")

    case reader.(path) do
      {:ok, %Triage{decision: :proceed} = triage} ->
        {:ok, {:proceed, triage}}

      {:ok, %Triage{decision: :flag} = triage} ->
        {:ok, {:flag, triage}}

      {:error, reason} ->
        {:ok, {:blocked, format_blocked_reason(reason, path)}}
    end
  end

  defp format_blocked_reason(reason, path) when is_binary(reason) do
    "TRIAGE.md unreadable at #{path}: #{reason}"
  end

  defp format_blocked_reason(reason, path) do
    "TRIAGE.md unreadable at #{path}: #{inspect(reason)}"
  end
end
