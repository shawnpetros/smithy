defmodule Smithy.Commands.AcknowledgeCmd do
  @moduledoc """
  `smithy acknowledge` subcommand. Prompts the operator for the
  hold-harmless acknowledgement and persists it. `--auto` skips the
  prompt for non-interactive setup; `--reset` clears an existing
  acknowledgement.
  """

  alias Smithy.Acknowledge

  @spec run([String.t()], map()) :: {:ok, String.t()} | {:error, term()}
  def run(_args, opts) when is_map(opts) do
    cond do
      Map.get(opts, :reset, false) ->
        case Acknowledge.reset() do
          :ok -> {:ok, "acknowledgement cleared"}
          err -> err
        end

      true ->
        run_opts = if Map.get(opts, :auto, false), do: [auto: true], else: []

        case Acknowledge.run(run_opts) do
          :ok -> {:ok, ""}
          {:error, :declined} -> {:error, :declined}
          err -> err
        end
    end
  end
end
