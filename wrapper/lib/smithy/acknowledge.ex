defmodule Smithy.Acknowledge do
  @moduledoc """
  Hold-harmless acknowledgement flow.

  Smithy runs agent workers with broad filesystem and shell permissions
  inside per-issue workspaces. Operators must acknowledge that they
  understand the implications before the wrapper will register repos or
  start daemons. The acknowledgement is one-time per machine, persisted
  as `acknowledged_at = "<iso8601>"` at the top of `~/.smithy/config.toml`.

  Symphony itself does not gate on this; the wrapper does. Operators who
  run Symphony directly bypass the gate (development case).
  """

  alias Smithy.Config

  @banner_lines [
    "Smithy runs coding agents (Codex, Claude Code) without sandboxing.",
    "Workers can read and write files in per-issue workspaces, execute",
    "shell commands, call external APIs, open PRs, and interact with",
    "Linear. Operate on machines and repos you trust.",
    "",
    "By acknowledging, you accept responsibility for what the harness",
    "does on your behalf. This is a one-time prompt per machine; the",
    "acknowledgement persists in ~/.smithy/config.toml."
  ]

  @prompt "Acknowledge and continue? [yes/no]: "

  @type io_fns :: %{
          gets: (String.t() -> String.t() | :eof),
          puts: (String.t() -> :ok),
          now: (-> DateTime.t())
        }

  @spec required?() :: boolean()
  def required?, do: not acknowledged?()

  @spec acknowledged?() :: boolean()
  def acknowledged? do
    case Config.load() do
      {:ok, config} -> Config.acknowledged?(config)
      _ -> false
    end
  end

  @doc """
  Prompts the operator interactively and persists the acknowledgement on
  yes. Returns `:ok` on yes, `{:error, :declined}` on no, `{:error, reason}`
  on IO or persistence failures.

  `:auto` opt skips the prompt and records the acknowledgement immediately.
  Use for non-interactive operators (CI, scripted setup).
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    io = io_fns(opts)
    auto? = Keyword.get(opts, :auto, false)

    if auto? do
      record(io)
    else
      print_banner(io)

      case prompt_yes_no(io) do
        :yes -> record(io)
        :no -> {:error, :declined}
        :eof -> {:error, :declined}
      end
    end
  end

  @doc "Resets the acknowledgement (next add-repo / daemon start will re-prompt)."
  @spec reset() :: :ok | {:error, term()}
  def reset do
    case Config.load() do
      {:ok, config} -> Config.write(%{config | acknowledged_at: nil})
      err -> err
    end
  end

  # ----- internals -----

  defp record(io) do
    timestamp =
      io.now.()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    case Config.load() do
      {:ok, config} ->
        case Config.write(%{config | acknowledged_at: timestamp}) do
          :ok ->
            io.puts.("Acknowledgement recorded at #{timestamp}.")
            :ok

          err ->
            err
        end

      err ->
        err
    end
  end

  defp print_banner(io) do
    border = String.duplicate("-", 70)
    io.puts.(border)
    io.puts.("Smithy hold-harmless acknowledgement")
    io.puts.(border)
    Enum.each(@banner_lines, fn line -> io.puts.(line) end)
    io.puts.(border)
  end

  defp prompt_yes_no(io) do
    case io.gets.(@prompt) do
      :eof ->
        :eof

      response when is_binary(response) ->
        case response |> String.trim() |> String.downcase() do
          "yes" -> :yes
          "y" -> :yes
          "no" -> :no
          "n" -> :no
          _ -> prompt_yes_no(io)
        end
    end
  end

  defp io_fns(opts) do
    %{
      gets: Keyword.get(opts, :gets, &default_gets/1),
      puts: Keyword.get(opts, :puts, &IO.puts/1),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0)
    }
  end

  defp default_gets(prompt) do
    case IO.gets(prompt) do
      :eof -> :eof
      {:error, _} -> :eof
      data when is_binary(data) -> data
    end
  end
end
