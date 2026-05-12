defmodule Smithy.Commands.StatusCmd do
  @moduledoc """
  Handler for `smithy status`, `smithy bellows`, `smithy forge`.

  Options:
    --json   emit JSON instead of TUI
    --snapshot emit one-shot ANSI status instead of interactive TUI
    --interval duration between interactive refreshes (for example 5s)
    --web    open the aggregate browser dashboard instead of printing
  """

  alias Smithy.{Config, Dashboard, Status, TUI}

  @type deps :: %{
          load: (-> {:ok, Config.t()} | {:error, term()}),
          collect: (Config.t() -> Status.aggregate()),
          write_dashboard: (Config.t() -> {:ok, String.t()} | {:error, term()}),
          open: (String.t() -> {:ok, String.t()} | {:error, term()}),
          interactive: (Config.t(), map() -> :ok | {:error, term()})
        }

  @spec run([String.t()], map(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(positional, opts \\ %{}, deps \\ default_deps())

  def run([], opts, deps) do
    with {:ok, config} <- deps.load.() do
      cond do
        Map.get(opts, :web) ->
          with {:ok, path} <- deps.write_dashboard.(config),
               {:ok, _} <- deps.open.("file://" <> path) do
            {:ok, "opened #{path}"}
          end

        Map.get(opts, :json) ->
          aggregate = deps.collect.(config)
          {:ok, Jason.encode!(json_safe(aggregate), pretty: true)}

        Map.get(opts, :snapshot) ->
          aggregate = deps.collect.(config)
          {:ok, TUI.render(aggregate, color: color?())}

        true ->
          with :ok <-
                 deps.interactive.(config, %{interval_ms: interval_ms(opts), color: color?()}) do
            {:ok, ""}
          end
      end
    end
  end

  def run(_, _, _), do: {:error, :usage}

  defp interval_ms(opts) do
    opts
    |> Map.get(:interval, "1s")
    |> parse_interval_ms()
  end

  defp parse_interval_ms(value) when is_integer(value) and value > 0, do: value

  defp parse_interval_ms(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.ends_with?(trimmed, "ms") ->
        parse_positive_integer(String.trim_trailing(trimmed, "ms"), 1_000)

      String.ends_with?(trimmed, "s") ->
        trimmed
        |> String.trim_trailing("s")
        |> parse_positive_integer(1)
        |> Kernel.*(1_000)

      true ->
        parse_positive_integer(trimmed, 1_000)
    end
  end

  defp parse_interval_ms(_value), do: 1_000

  defp parse_positive_integer(value, fallback) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> fallback
    end
  end

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(atom) when atom in [nil, true, false], do: atom
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: to_string(key)

  defp color?, do: System.get_env("NO_COLOR") in [nil, ""] and IO.ANSI.enabled?()

  defp default_deps do
    %{
      load: fn -> Config.load() end,
      collect: fn config -> Status.collect(config) end,
      write_dashboard: fn config -> Dashboard.write_aggregate_html(config) end,
      open: fn target -> Dashboard.open(target) end,
      interactive: fn config, tui_opts -> TUI.run(config, tui_opts) end
    }
  end
end
