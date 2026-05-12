defmodule SymphonyElixir.Modes.Reviewer do
  @moduledoc """
  Orchestrates a single adversarial-review pass on an issue parked in the
  `Adversarial Review` state.

  Reads the PR diff (or `git diff main...HEAD` fallback), spawns the
  reviewer agent via the runtime adapter for `agent_config.runtime`, parses
  the `REVIEW.md` the agent writes at the workspace root, and returns a
  structured outcome the orchestrator uses to transition Linear state.

  Ported from Anvil's `src/review.rs` per v2/SPEC.md "mode: reviewer". No
  Linear writes happen here; the orchestrator owns every state move and
  label.

  ## Outcome contract

    * `{:pass, %Review{}}`    -> next state `Human Review` (or `Merging`
      when `:auto_merge` is true; see `next_state/2`)
    * `{:fail, %Review{}}`    -> next state `Rework`
    * `{:blocked, reason}`    -> stays in `Adversarial Review`; the
      orchestrator applies `harness-blocked` separately

  ## Tool denylist

  Reviewer spawns get a denylist via `:disallowed_tools` so a misbehaving
  reviewer cannot mutate Linear. Edit/Write are also denied at the
  argv-flag level for belt-and-suspenders. The reviewer needs to write
  REVIEW.md, so in v1 we keep Write allowed for now (option A in the
  ticket) and rely on the persona prompt to constrain its use. Hardening
  this (sentinel REVIEW.md + Edit-only) is future work tracked in the spec.

  ## Injectable IO

  All IO routes through opts so tests run without forking processes:

    * `:adapter`         - runtime adapter module (defaults to
      `SymphonyElixir.Runtime.adapter_for(agent_config.runtime)`)
    * `:persona_loader`  - `(path -> {:ok, Persona.t()} | {:error, _})`
      (defaults to `Persona.load/1`)
    * `:diff_fetcher`    - `(workspace, issue -> {:ok, diff} | {:error, _})`
      (defaults to `default_diff_fetcher/2`, which shells to `gh pr diff`
      then `git diff main...HEAD`)
    * `:review_reader`   - `(path -> {:ok, Review.t()} | {:error, _})`
      (defaults to `Review.parse_file/1`)
    * `:project_dir`     - directory to search for repo-local persona
      overrides at `<project_dir>/.smithy/personas/<name>.md` (defaults
      to `File.cwd!/0`)
    * `:mcp_config_path` - path to a pre-rendered `--mcp-config` JSON; if
      absent, the adapter receives `nil` and decides how to handle it
    * `:on_message`      - turn event callback forwarded to the adapter
  """

  require Logger

  alias SymphonyElixir.Handoff.Review
  alias SymphonyElixir.Personas.Persona
  alias SymphonyElixir.Runtime

  @type issue :: SymphonyElixir.Linear.Issue.t() | map()
  @type agent_config :: SymphonyElixir.Config.Schema.AgentConfig.t()
  @type review_outcome ::
          {:pass, Review.t()}
          | {:fail, Review.t()}
          | {:blocked, reason :: String.t()}

  # v1 keeps Write allowed so the reviewer can emit REVIEW.md. Persona prompt
  # constrains usage to "REVIEW.md only" via the body text. Future hardening
  # (pre-seed REVIEW.md sentinel + restrict to Edit) tracked in v2/SPEC.md
  # roadmap. Edit is also kept since the reviewer may iterate on its REVIEW.md
  # within a single turn.
  @reviewer_disallowed_tools [
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
  Run the reviewer pass on `issue` within `workspace`.

  The function never raises. Adapter failures bubble back as
  `{:error, term()}`. Persona-load or diff-fetch failures also surface as
  `{:error, _}`. Only REVIEW.md problems convert to `{:ok, {:blocked, _}}`,
  because the reviewer DID run and the orchestrator should record the run
  before parking the ticket.
  """
  @spec run(issue(), Path.t(), agent_config(), keyword()) ::
          {:ok, review_outcome()} | {:error, term()}
  def run(issue, workspace, agent_config, opts \\ []) do
    with {:ok, persona_path} <- resolve_persona_path(agent_config, opts),
         {:ok, persona} <- load_persona(persona_path, opts),
         {:ok, diff} <- fetch_diff(workspace, issue, opts),
         rendered = render_prompt(persona, issue, workspace, diff),
         {:ok, _result} <-
           spawn_reviewer(workspace, agent_config, persona_path, rendered, issue, opts) do
      classify_review(workspace, opts)
    end
  end

  @doc """
  Map the reviewer's outcome to the next Linear state name.

  Per v2/SPEC.md "State machine":

    * pass     -> "Human Review", or "Merging" when `:auto_merge` is true
    * fail     -> "Rework"
    * blocked  -> "Adversarial Review" (no transition; orchestrator
      attaches `harness-blocked` label out-of-band)
  """
  @spec next_state(review_outcome(), keyword()) :: String.t()
  def next_state({:pass, _review}, opts) do
    if Keyword.get(opts, :auto_merge, false) do
      "Merging"
    else
      "Human Review"
    end
  end

  def next_state({:fail, _review}, _opts), do: "Rework"

  def next_state({:blocked, _reason}, _opts), do: "Adversarial Review"

  @doc """
  The reviewer-specific tool denylist surfaced for orchestrator logging,
  config inspection, and tests.
  """
  @spec disallowed_tools() :: [String.t()]
  def disallowed_tools, do: @reviewer_disallowed_tools

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
        # Three candidates, in priority order:
        #   1. :code.priv_dir/1 result. Works when running from source.
        #   2. <project_dir>/elixir/priv/personas/<name>. Works inside an agent
        #      workspace where the project_dir is a clone of the smithy repo.
        #      Also the escape hatch when running as an escript (where priv_dir
        #      returns the escript binary path, which is not a directory).
        #   3. <project_dir>/.smithy/personas/<name>. Repo-local override slot.
        workspace_priv = Path.join([project_dir, "elixir", "priv", @personas_subdir, filename])
        repo_path = Path.join([project_dir, @repo_personas_subdir, filename])
        [priv_path, workspace_priv, repo_path]
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

  # --- diff fetch ----------------------------------------------------------

  defp fetch_diff(workspace, issue, opts) do
    fetcher = Keyword.get(opts, :diff_fetcher, &default_diff_fetcher/2)

    case fetcher.(workspace, issue) do
      {:ok, diff} when is_binary(diff) -> {:ok, diff}
      {:ok, other} -> {:error, {:invalid_diff, other}}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec default_diff_fetcher(Path.t(), issue()) :: {:ok, String.t()} | {:error, term()}
  def default_diff_fetcher(workspace, issue) do
    case pr_number(issue) do
      {:ok, number} ->
        case run_cmd(workspace, "gh", ["pr", "diff", to_string(number)]) do
          {:ok, diff} ->
            {:ok, diff}

          {:error, _} ->
            git_diff_fallback(workspace)
        end

      :error ->
        git_diff_fallback(workspace)
    end
  end

  defp git_diff_fallback(workspace) do
    case run_cmd(workspace, "git", ["diff", "main...HEAD"]) do
      {:ok, diff} -> {:ok, diff}
      {:error, reason} -> {:error, {:diff_unavailable, reason}}
    end
  end

  defp run_cmd(workspace, executable, args) do
    # `stderr_to_stdout: true` keeps the noise inside `output` instead of
    # leaking to the test runner / caller's stderr. We do not parse it; we
    # just need the exit code.
    case System.cmd(executable, args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {executable, code, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {executable, :enoent, Exception.message(e)}}
  end

  defp pr_number(issue) do
    case Map.get(issue || %{}, :pr_number) || Map.get(issue || %{}, "pr_number") do
      nil -> :error
      n when is_integer(n) -> {:ok, n}
      n when is_binary(n) -> {:ok, n}
      _ -> :error
    end
  end

  # --- prompt rendering ----------------------------------------------------

  defp render_prompt(persona, issue, workspace, diff) do
    vars = %{
      "identifier" => string_field(issue, :identifier),
      "title" => string_field(issue, :title),
      "description" => string_field(issue, :description),
      "branch" => string_field(issue, :branch_name),
      "workspace_path" => to_string(workspace),
      "diff" => diff
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

  # --- adapter spawn -------------------------------------------------------

  defp spawn_reviewer(workspace, agent_config, persona_path, rendered, issue, opts) do
    adapter = resolve_adapter(agent_config, opts)
    on_message = Keyword.get(opts, :on_message, &noop_on_message/1)

    session_opts =
      [
        persona_path: persona_path,
        tier: agent_config.tier,
        disallowed_tools: @reviewer_disallowed_tools,
        mcp_config_path: Keyword.get(opts, :mcp_config_path),
        mode: :reviewer,
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

  # --- REVIEW.md classification -------------------------------------------

  defp classify_review(workspace, opts) do
    reader = Keyword.get(opts, :review_reader, &Review.parse_file/1)
    path = Path.join(workspace, "REVIEW.md")

    case reader.(path) do
      {:ok, %Review{status: :pass} = review} ->
        {:ok, {:pass, review}}

      {:ok, %Review{status: :fail} = review} ->
        {:ok, {:fail, review}}

      {:error, reason} ->
        {:ok, {:blocked, format_blocked_reason(reason, path)}}
    end
  end

  defp format_blocked_reason(reason, path) when is_binary(reason) do
    "REVIEW.md unreadable at #{path}: #{reason}"
  end

  defp format_blocked_reason(reason, path) do
    "REVIEW.md unreadable at #{path}: #{inspect(reason)}"
  end
end
