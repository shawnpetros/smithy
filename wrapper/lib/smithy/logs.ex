defmodule Smithy.Logs do
  @moduledoc """
  `smithy logs <slug> [--follow]` - print or tail the daemon log for a
  registered repo. Logs live at `~/.smithy/logs/<slug>/{stdout,stderr}.log`
  per the launchd plist convention.
  """

  alias Smithy.Supervisor

  @type io_target :: IO.device() | (binary() -> :ok)

  @doc """
  Returns the path to the stdout log for a slug.
  """
  @spec stdout_path(String.t()) :: String.t()
  def stdout_path(slug), do: Path.join(Supervisor.logs_dir(slug), "stdout.log")

  @doc """
  Returns the path to the stderr log for a slug.
  """
  @spec stderr_path(String.t()) :: String.t()
  def stderr_path(slug), do: Path.join(Supervisor.logs_dir(slug), "stderr.log")

  @doc """
  Prints the current contents of the slug's stdout log to `io`. If
  `follow?` is true, shells out to `tail -f`. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec print(String.t(), boolean(), io_target()) :: :ok | {:error, term()}
  def print(slug, follow? \\ false, io \\ :stdio) do
    path = stdout_path(slug)

    cond do
      not File.exists?(path) ->
        {:error, {:no_log, path}}

      follow? ->
        # Foreground `tail -f`. We rely on shell since rolling our own
        # follower in Elixir isn't worth the code.
        System.cmd("tail", ["-f", path], into: io)
        :ok

      true ->
        case File.read(path) do
          {:ok, body} ->
            IO.write(io, body)
            :ok

          err ->
            err
        end
    end
  end
end
