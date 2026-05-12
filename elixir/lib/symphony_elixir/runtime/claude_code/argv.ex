defmodule SymphonyElixir.Runtime.ClaudeCode.Argv do
  @moduledoc """
  Builds argv lists for invoking `claude` as a Symphony worker subprocess.

  The flag set is non-obvious. Defaults are based on smithy-v1's PER-44/PER-31/PER-36
  worker construction, which was empirically tuned against real Linear-driven runs:

    * `--setting-sources project,local` — skip the operator's user-scope
      `~/.claude/settings.json`. SessionStart hooks (vault sync, wrapup, deaiify,
      etc.) and user-scope CLAUDE.md cost ~30k input tokens per session-start.
      OAuth, keychain auth, and user-scope MCP server configs live OUTSIDE
      settings and stay active. This is the right knob; `--bare` is too aggressive
      and would also drop OAuth.
    * `--dangerously-skip-permissions` — auto-approve tool calls. Workers run in
      sandboxed per-issue workspaces; the operator opted in by configuring this
      runtime in WORKFLOW.md.
    * `--model claude-{opus-4-7|sonnet-4-6|haiku-4-5}` — explicit per-tier model.
      Always passed (even on default) so the spawn log shows the choice.
    * `--disallowedTools <list>` — revoke Linear MCP write tools. The orchestrator
      owns all state transitions; agents communicate via RESULT.md / REVIEW.md.
    * `--output-format stream-json --verbose` — JSONL on stdout for the dashboard,
      stall watchdog, and EventParser.
    * `-p` (`--print`) — non-interactive, exit after response.

  Multi-turn continuation is handled by passing `--continue <session_id>` on
  subsequent invocations; this module supports that via `:session_id` opt.
  """

  @typedoc "Model tier per PER-36 (smithy-v1 lineage). Maps to a concrete `claude-*` model id."
  @type tier :: :opus | :sonnet | :haiku

  @typedoc """
  Options for `build/2`:

    * `:tier` (default `:sonnet`) - model tier
    * `:disallowed_tools` (default Linear write set) - list of MCP tool ids to deny
    * `:session_id` (optional) - resume an existing Claude Code session
    * `:max_budget_usd` (optional) - pass `--max-budget-usd N` for hard cost cap
    * `:append_system_prompt` (optional) - string for `--append-system-prompt`
    * `:add_dirs` (optional) - list of extra dirs for `--add-dir`
    * `:mcp_config` (optional) - path to a generated mcp config JSON file. When
      set, the builder emits `--mcp-config <path>`. Symphony's MCP bundle module
      writes this file before spawn.
    * `:strict_mcp_config` (default false) - when true, emits `--strict-mcp-config`
      so user-scope MCP servers don't leak in. Only meaningful in conjunction
      with `:mcp_config`. Defaults to false to preserve backward compatibility
      with callers that don't yet generate a bundle JSON.
  """
  @type opts :: [
          tier: tier(),
          disallowed_tools: [String.t()],
          session_id: String.t() | nil,
          max_budget_usd: number() | nil,
          append_system_prompt: String.t() | nil,
          add_dirs: [Path.t()],
          mcp_config: Path.t() | nil,
          strict_mcp_config: boolean()
        ]

  @default_disallowed_tools [
    # Linear MCP write tools, per claude's `mcp__<server>__<tool>` qualification.
    # If the user-scope server is registered under a different display name
    # (e.g. "claude.ai Linear"), include both forms via config.
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

  @doc """
  Build the argv list to pass after the prompt (or via stdin, depending on caller).

  The returned list is suitable for `Port.open({:spawn_executable, claude_bin}, [args: argv, ...])`.
  Does NOT include the prompt itself; that's appended by the caller as a positional
  argument or written to stdin.
  """
  @spec build(String.t(), opts()) :: [String.t()]
  def build(claude_bin, opts \\ []) when is_binary(claude_bin) and is_list(opts) do
    tier = Keyword.get(opts, :tier, :sonnet)
    disallowed = Keyword.get(opts, :disallowed_tools, @default_disallowed_tools)
    session_id = Keyword.get(opts, :session_id)
    max_budget = Keyword.get(opts, :max_budget_usd)
    append_sp = Keyword.get(opts, :append_system_prompt)
    add_dirs = Keyword.get(opts, :add_dirs, [])
    mcp_config = Keyword.get(opts, :mcp_config)
    strict_mcp = Keyword.get(opts, :strict_mcp_config, false)

    base = [
      "-p",
      "--setting-sources",
      "project,local",
      "--dangerously-skip-permissions",
      "--model",
      model_for_tier(tier),
      "--disallowedTools",
      Enum.join(disallowed, " "),
      "--output-format",
      "stream-json",
      "--verbose"
    ]

    base
    |> maybe_append(session_id, fn id -> ["--continue", id] end)
    |> maybe_append(max_budget, fn n -> ["--max-budget-usd", to_string(n)] end)
    |> maybe_append(append_sp, fn sp -> ["--append-system-prompt", sp] end)
    |> append_add_dirs(add_dirs)
    |> append_mcp_config(mcp_config, strict_mcp)
  end

  @doc "Canonical `claude-*` model id per tier."
  @spec model_for_tier(tier() | String.t()) :: String.t()
  def model_for_tier(:opus), do: "claude-opus-4-7"
  def model_for_tier(:sonnet), do: "claude-sonnet-4-6"
  def model_for_tier(:haiku), do: "claude-haiku-4-5"
  def model_for_tier("opus"), do: "claude-opus-4-7"
  def model_for_tier("sonnet"), do: "claude-sonnet-4-6"
  def model_for_tier("haiku"), do: "claude-haiku-4-5"
  def model_for_tier(_unknown), do: "claude-sonnet-4-6"

  @doc "Default disallowed tool list. Exposed for tests and operator overrides."
  @spec default_disallowed_tools() :: [String.t()]
  def default_disallowed_tools, do: @default_disallowed_tools

  # ----- internal helpers -----

  defp maybe_append(args, nil, _builder), do: args
  defp maybe_append(args, value, builder), do: args ++ builder.(value)

  defp append_add_dirs(args, []), do: args

  defp append_add_dirs(args, dirs) when is_list(dirs) do
    args ++ ["--add-dir"] ++ dirs
  end

  # No MCP config path: ignore strict flag too. `--strict-mcp-config` only makes
  # sense when paired with a generated bundle file, otherwise claude rejects it.
  defp append_mcp_config(args, nil, _strict), do: args

  defp append_mcp_config(args, path, true) when is_binary(path) do
    args ++ ["--strict-mcp-config", "--mcp-config", path]
  end

  defp append_mcp_config(args, path, _strict) when is_binary(path) do
    args ++ ["--mcp-config", path]
  end
end
