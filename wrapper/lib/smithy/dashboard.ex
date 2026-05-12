defmodule Smithy.Dashboard do
  @moduledoc """
  `smithy dashboard [slug]` launches a browser at the appropriate URL.

  - No slug: aggregate dashboard. v1 ships a tiny iframe-grid HTML page
    written to `~/.smithy/dashboard.html` and opened locally. v2 polish
    replaces this with a native unified dashboard.
  - With slug: opens `http://localhost:<port>/` for that repo's
    Symphony LiveView.
  """

  alias Smithy.Config

  @type opener :: (String.t() -> {String.t(), non_neg_integer()})

  @doc """
  Builds the aggregate iframe-grid HTML for a config. Pure.
  """
  @spec aggregate_html(Config.t()) :: String.t()
  def aggregate_html(config) do
    cells =
      config.repos
      |> Enum.map(fn r ->
        url = "http://localhost:#{r.port}/"

        """
        <div class="cell">
          <div class="cell-header">[#{r.slug}] <a href="#{url}" target="_blank">#{url}</a></div>
          <iframe src="#{url}" loading="lazy"></iframe>
        </div>
        """
      end)
      |> Enum.join("\n")

    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Smithy Aggregate Dashboard</title>
      <style>
        :root { color-scheme: dark light; font-family: ui-monospace, monospace; }
        body { margin: 0; padding: 12px; background: #111; color: #eee; }
        h1 { font-size: 16px; margin: 0 0 12px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(480px, 1fr)); gap: 12px; }
        .cell { border: 1px solid #333; border-radius: 6px; overflow: hidden; }
        .cell-header { padding: 6px 10px; background: #222; font-size: 12px; }
        .cell iframe { width: 100%; height: 540px; border: 0; background: white; }
        a { color: #6cf; }
      </style>
    </head>
    <body>
      <h1>SMITHY  -  aggregate dashboard</h1>
      <div class="grid">
        #{cells}
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Writes the aggregate HTML to `~/.smithy/dashboard.html` and returns the
  file path.
  """
  @spec write_aggregate_html(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def write_aggregate_html(config) do
    path = Path.expand("~/.smithy/dashboard.html")
    body = aggregate_html(config)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body) do
      {:ok, path}
    end
  end

  @doc """
  Opens a URL (or file path) using the platform-appropriate launcher.
  """
  @spec open(String.t(), opener()) :: {:ok, String.t()} | {:error, term()}
  def open(target, opener \\ &default_opener/1) do
    case opener.(target) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {out, status}}
    end
  end

  defp default_opener(target) do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> "open"
        _ -> "xdg-open"
      end

    System.cmd(cmd, [target], stderr_to_stdout: true)
  end
end
