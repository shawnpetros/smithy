defmodule Smithy.Supervisor do
  @moduledoc """
  launchd plist generation and load/unload.

  macOS-only in v1. Linux `systemd` support is a follow-up; see
  `v2/SPEC.md` § "Smithy wrapper".
  """

  alias Smithy.Config

  @plist_label_prefix "com.shawnpetros.smithy"
  # Template lives under priv/templates/. Use Application.app_dir/2 lazily so
  # the lookup works whether we're in mix, in an escript, or in tests.
  @template_relative "templates/launchd.plist.eex"

  @type cmd_runner :: (String.t(), [String.t()] -> {String.t(), non_neg_integer()})

  @doc """
  Returns the launchd label for a given slug, e.g.
  `com.shawnpetros.smithy.smithy`.
  """
  @spec label(String.t()) :: String.t()
  def label(slug), do: "#{@plist_label_prefix}.#{slug}"

  @doc """
  Returns the path on disk where the plist for a slug should live, under
  `~/Library/LaunchAgents/`.
  """
  @spec plist_path(String.t()) :: String.t()
  def plist_path(slug) do
    Path.expand("~/Library/LaunchAgents/#{label(slug)}.plist")
  end

  @doc """
  Returns the logs directory for a slug, under `~/.smithy/logs/<slug>/`.
  """
  @spec logs_dir(String.t()) :: String.t()
  def logs_dir(slug), do: Path.expand("~/.smithy/logs/#{slug}")

  # Env vars the wrapper captures from the operator's shell at `smithy
  # add-repo` time and bakes into the launchd plist's EnvironmentVariables
  # block. Symphony's tracker / git / agent runners read these via
  # System.get_env. launchd does NOT inherit the operator's shell env, so
  # without this capture the daemon polls Linear silently and gets rejected.
  @captured_env_vars [
    "LINEAR_API_KEY",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "CODEX_HOME",
    # Alerts (PER-190): bake Telegram credentials into the plist so the
    # launchd-supervised daemon can reach the Telegram Bot API without
    # manual launchctl setenv. Required for alerts.enabled = true to
    # produce any messages from the production daemon path.
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CHAT_ID"
  ]

  @doc """
  Renders the plist XML for a registered repo. Pure: no filesystem effect.

  The plist sets EnvironmentVariables.PATH so launchd can find `escript`
  (needed by Symphony's escript shebang) plus any other binaries the
  workflow hooks may shell out to. It also captures a set of API-key env
  vars from the operator's shell so the daemon can authenticate to Linear,
  GitHub, and the agent runtimes without manual launchctl setenv.
  """
  @spec render_plist(Config.repo(), Config.t()) :: String.t()
  def render_plist(repo, config) do
    assigns = [
      repo: %{
        slug: repo.slug,
        path: repo.path,
        workflow: repo.workflow,
        port: repo.port,
        logs_dir: logs_dir(repo.slug),
        symphony_binary: config.symphony_binary,
        path_env: path_env_for_launchd(),
        captured_env: captured_env_for_launchd()
      }
    ]

    EEx.eval_file(template_path(), assigns)
  end

  @doc false
  # Composes the PATH value baked into the generated plist's
  # EnvironmentVariables block. Captures the operator's current PATH at
  # registration time and prepends it onto the launchd default, so escript,
  # mise, git, gh, and friends resolve in the daemon's environment.
  @spec path_env_for_launchd() :: String.t()
  def path_env_for_launchd do
    base = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    operator = System.get_env("PATH") || ""

    [operator, base]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(":")
  end

  @doc false
  # Captures a set of known env vars (API keys, runtime homes) from the
  # operator's shell at registration time. Returns a list of {key, value}
  # tuples that the plist template renders into EnvironmentVariables.
  # Skips vars that are unset; never injects empty strings.
  @spec captured_env_for_launchd() :: [{String.t(), String.t()}]
  def captured_env_for_launchd do
    @captured_env_vars
    |> Enum.map(fn key -> {key, System.get_env(key)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  @doc "Exposed for tests + operator-facing diagnostics."
  @spec captured_env_var_names() :: [String.t()]
  def captured_env_var_names, do: @captured_env_vars

  @doc """
  Writes the plist to disk under `~/Library/LaunchAgents/`. Also ensures
  the logs directory exists.
  """
  @spec install(Config.repo(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def install(repo, config) do
    plist = render_plist(repo, config)
    target = plist_path(repo.slug)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.mkdir_p(logs_dir(repo.slug)),
         :ok <- File.write(target, plist) do
      {:ok, target}
    end
  end

  @doc """
  Removes the plist from disk if it exists. No-op if missing.
  """
  @spec uninstall(String.t()) :: :ok | {:error, term()}
  def uninstall(slug) do
    target = plist_path(slug)

    case File.rm(target) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      err -> err
    end
  end

  @doc """
  Loads the plist via `launchctl load`. Pass an injectable `cmd_runner`
  for testability.
  """
  @spec load(String.t(), cmd_runner()) :: {:ok, String.t()} | {:error, {String.t(), integer()}}
  def load(slug, cmd_runner \\ &default_cmd_runner/2) do
    run_launchctl(["load", "-w", plist_path(slug)], cmd_runner)
  end

  @doc """
  Unloads the plist via `launchctl unload`.
  """
  @spec unload(String.t(), cmd_runner()) :: {:ok, String.t()} | {:error, {String.t(), integer()}}
  def unload(slug, cmd_runner \\ &default_cmd_runner/2) do
    run_launchctl(["unload", "-w", plist_path(slug)], cmd_runner)
  end

  @doc """
  Restart (unload then load). Returns first error if either fails.
  """
  @spec restart(String.t(), cmd_runner()) :: {:ok, String.t()} | {:error, term()}
  def restart(slug, cmd_runner \\ &default_cmd_runner/2) do
    _ = unload(slug, cmd_runner)
    load(slug, cmd_runner)
  end

  defp run_launchctl(args, cmd_runner) do
    case cmd_runner.("launchctl", args) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {out, status}}
    end
  end

  defp default_cmd_runner(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  end

  defp template_path do
    candidates = [
      Path.join(priv_dir(), @template_relative),
      Path.join([File.cwd!(), "priv", @template_relative]),
      Path.join([__DIR__, "..", "..", "priv", @template_relative])
    ]

    Enum.find(candidates, &File.exists?/1) || hd(candidates)
  end

  defp priv_dir do
    case :code.priv_dir(:smithy) do
      {:error, _} -> "priv"
      path -> to_string(path)
    end
  end
end
