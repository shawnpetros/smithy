defmodule Smithy.CLI do
  @moduledoc """
  Escript entry point. Dispatches subcommands to handler modules in
  `Smithy.Commands.*`.

  See `README.md` and `v2/SPEC.md` § "Smithy wrapper" for the surface.
  """

  alias Smithy.Acknowledge

  alias Smithy.Commands.{
    AcknowledgeCmd,
    AddRepo,
    DaemonCmd,
    DashboardCmd,
    ListRepos,
    LogsCmd,
    RemoveRepo,
    StatusCmd
  }

  @switches [
    workflow: :string,
    port: :integer,
    follow: :boolean,
    web: :boolean,
    json: :boolean,
    help: :boolean,
    auto: :boolean,
    reset: :boolean
  ]
  @aliases [h: :help, f: :follow]

  # Subcommands that mutate or operate the harness require a prior
  # hold-harmless acknowledgement. Read-only and meta commands do not.
  @gated_commands ~w(add-repo remove-repo daemon)

  @spec main([String.t()]) :: :ok
  def main(argv) do
    case dispatch(argv) do
      {:ok, output} ->
        if output != "", do: IO.puts(output)
        :ok

      {:error, :usage} ->
        IO.puts(:stderr, usage())
        exit_with(64)

      {:error, {:duplicate_slug, slug}} ->
        IO.puts(:stderr, "error: slug already registered: #{slug}")
        exit_with(65)

      {:error, {:duplicate_port, port}} ->
        IO.puts(:stderr, "error: port already in use: #{port}")
        exit_with(65)

      {:error, :not_found} ->
        IO.puts(:stderr, "error: repo not found")
        exit_with(66)

      {:error, :acknowledgement_required} ->
        IO.puts(:stderr, "error: hold-harmless acknowledgement required. Run `smithy acknowledge` first.")
        exit_with(67)

      {:error, :declined} ->
        IO.puts(:stderr, "acknowledgement declined; aborting.")
        exit_with(68)

      {:error, reason} ->
        IO.puts(:stderr, "error: #{inspect(reason)}")
        exit_with(1)
    end
  end

  @doc """
  Pure dispatch: takes argv, returns `{:ok, output}` or `{:error, reason}`.
  Exposed so tests can hit the surface without exiting.
  """
  @spec dispatch([String.t()]) :: {:ok, String.t()} | {:error, term()}
  def dispatch(argv) do
    cond do
      argv == ["--version"] or argv == ["version"] ->
        {:ok, "smithy #{Smithy.version()}"}

      argv == ["--help"] or argv == ["help"] or argv == [] ->
        {:ok, usage()}

      true ->
        {opts, positional, _invalid} =
          OptionParser.parse(argv, switches: @switches, aliases: @aliases)

        opts_map = Map.new(opts)

        if Map.get(opts_map, :help, false) do
          {:ok, usage()}
        else
          do_dispatch(positional, opts_map)
        end
    end
  end

  defp do_dispatch([], _opts), do: {:ok, usage()}
  defp do_dispatch(["help"], _opts), do: {:ok, usage()}
  defp do_dispatch(["--help"], _opts), do: {:ok, usage()}
  defp do_dispatch(["version"], _opts), do: {:ok, "smithy #{Smithy.version()}"}
  defp do_dispatch(["--version"], _opts), do: {:ok, "smithy #{Smithy.version()}"}

  defp do_dispatch(["acknowledge" | rest], opts), do: AcknowledgeCmd.run(rest, opts)

  defp do_dispatch([command | _] = argv, opts) when command in @gated_commands do
    if Acknowledge.acknowledged?() do
      route(argv, opts)
    else
      {:error, :acknowledgement_required}
    end
  end

  defp do_dispatch(argv, opts), do: route(argv, opts)

  defp route(["add-repo" | rest], opts), do: AddRepo.run(rest, opts)
  defp route(["remove-repo" | rest], opts), do: RemoveRepo.run(rest, opts)
  defp route(["list-repos" | rest], opts), do: ListRepos.run(rest, opts)

  defp route(["status" | rest], opts), do: StatusCmd.run(rest, opts)
  defp route(["bellows" | rest], opts), do: StatusCmd.run(rest, opts)
  defp route(["forge" | rest], opts), do: StatusCmd.run(rest, opts)

  defp route(["dashboard" | rest], opts), do: DashboardCmd.run(rest, opts)
  defp route(["logs" | rest], opts), do: LogsCmd.run(rest, opts)
  defp route(["daemon" | rest], opts), do: DaemonCmd.run(rest, opts)

  defp route([unknown | _], _), do: {:error, {:unknown_command, unknown}}

  defp usage do
    """
    Smithy v#{Smithy.version()} - thin supervisor for N Symphony daemons.

    USAGE
      smithy <command> [args] [options]

    COMMANDS
      version                              print version
      help                                 show this message

      acknowledge                          one-time hold-harmless acknowledgement
        --auto                             skip the interactive prompt
        --reset                             clear an existing acknowledgement

      add-repo <slug> <path>               register a repo, generate launchd plist
        --workflow PATH                    workflow file (default: WORKFLOW.md)
        --port PORT                        port (auto-assigned from 4001 if omitted)
      remove-repo <slug>                   deregister + stop + remove plist
      list-repos                           print registered repos

      status [--web] [--json]              aggregate TUI; --web opens browser
      bellows                              alias for status
      forge                                alias for status
      dashboard [slug]                     open repo or aggregate dashboard
      logs <slug> [--follow]               tail one repo's stdout log

      daemon start [slug]                  launchctl load (all repos if no slug)
      daemon stop [slug]                   launchctl unload
      daemon restart [slug]                stop + start

    NOTES
      Config:  ~/.smithy/config.toml
      Logs:    ~/.smithy/logs/<slug>/{stdout,stderr}.log
      Plists:  ~/Library/LaunchAgents/com.shawnpetros.smithy.<slug>.plist
      macOS only in v1; systemd unit ships in a follow-up.
    """
  end

  defp exit_with(code) do
    # Tests set SMITHY_NO_HALT=1 so they can assert on output without the VM exiting.
    if System.get_env("SMITHY_NO_HALT") in [nil, ""] do
      System.halt(code)
    else
      throw({:exit_with, code})
    end
  end
end
