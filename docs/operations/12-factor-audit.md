# Smithy/Symphony 12-Factor Audit

Date: 2026-05-12

Scope: this audit covers the Smithy wrapper in `wrapper/` and the Symphony
orchestrator in `elixir/`. It is bounded to the 12 factors and to the concrete
runtime knobs present in the current repo.

## Summary

| Factor | Verdict | Notes |
| --- | --- | --- |
| I. Codebase | Compliant | One repo, two releaseable apps in the same codebase. |
| II. Dependencies | Compliant | Mix and mise declare dependencies; shell tools are operator prerequisites. |
| III. Config | Compliant | Runtime config is in env, `WORKFLOW.md`, or `~/.smithy/config.toml`; one hardcoded runtime default now has an env fallback. |
| IV. Backing Services | Compliant | Linear, GitHub, model runtimes, and SSH workers are attached by config/env. |
| V. Build, Release, Run | Compliant | Build artifacts and runtime config are separate for the current prototype. |
| VI. Processes | Compliant | Worker state is disposable; durable state is in Linear/workspaces/telemetry. |
| VII. Port Binding | Compliant | Phoenix binds on `server.port` or CLI `--port`. |
| VIII. Concurrency | Compliant | Agent concurrency is controlled by config and BEAM processes. |
| IX. Disposability | Partial | Startup is fast; explicit shutdown drain semantics are not proven. |
| X. Dev/Prod Parity | Compliant | Foreground and launchd runs invoke the same binary and workflow file. |
| XI. Logs | Partial | File-routed launchd logs remain supported; stdout streaming is now available. |
| XII. Admin Processes | Compliant | Admin commands use the same wrapper code and config. |

## Runtime Knob Inventory

### Environment Variables

These are correct as env vars because they are secrets, host integration points,
or operator terminal preferences:

| Variable | Consumer | Verdict |
| --- | --- | --- |
| `LINEAR_API_KEY` | `Config.Schema` and bundled Linear MCP config | Correct. Secret. |
| `LINEAR_ASSIGNEE` | `Config.Schema` | Correct. Operator-specific routing. |
| `GH_TOKEN` / `GITHUB_TOKEN` | Smithy launchd env capture for workers | Correct. Secret. |
| `ANTHROPIC_API_KEY` | Claude Code runtime environment | Correct. Secret. |
| `OPENAI_API_KEY` | Optional agent/runtime environment | Correct. Secret. |
| `CODEX_HOME` | Codex runtime environment | Correct. Host runtime location. |
| `HOME` | Smithy config path resolution | Correct. Host identity. |
| `PATH` | Smithy launchd env capture and command resolution | Correct. Host integration. |
| `NO_COLOR`, `COLUMNS` | CLI/status rendering | Correct. Terminal presentation. |
| `SYMPHONY_SSH_CONFIG` | SSH config override | Correct. Host integration. |
| `SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS` | Claude Code turn timeout fallback | Added by this audit. Operator runtime control with default `600000`. |

Test-only/live-E2E variables such as `SYMPHONY_RUN_LIVE_E2E`,
`SYMPHONY_LIVE_LINEAR_TEAM_KEY`, `SYMPHONY_LIVE_SSH_WORKER_HOSTS`,
`SYMPHONY_LIVE_DOCKER_AUTH_JSON`, and `SYMPHONY_LIVE_DOCKER_AUTHORIZED_KEY`
are not production runtime knobs.

### `WORKFLOW.md`

These are correctly file-backed because they describe the deployed workflow, not
per-process secrets:

| Block | Runtime knobs | Verdict |
| --- | --- | --- |
| `tracker` | kind, endpoint, project slug, labels, assignee, active/terminal states | File-backed. `api_key` supports `$VAR` and `LINEAR_API_KEY` fallback. |
| `polling` | `interval_ms` | File-backed. Environment override is unnecessary for v1. |
| `workspace` | workspace root | File-backed. Supports `$VAR` for staging/prod paths. |
| `worker` | SSH hosts, per-host concurrency | File-backed. Deployment topology. |
| `agent` | total concurrency, max turns, retry backoff cap, per-state limits | File-backed. Operational policy. |
| `codex` | command, approval policy, sandbox policy, Codex timeouts | File-backed. Runtime policy. |
| `hooks` | lifecycle hooks and hook timeout | File-backed. Workflow contract. |
| `observability` | dashboard enabled, refresh interval, render interval | File-backed. Operator UI behavior. |
| `server` | host and port | File-backed, with CLI `--port` override for process launch. |
| `agents` | builder/reviewer/triager mode, runtime, persona, MCP bundle, tier | File-backed. Deployment workflow, not secret. |

Staging vs production can use separate `WORKFLOW.md` files. The audit does not
recommend env-overriding `tracker.project_slug`, labels, or agents for v1
because those values define the workflow identity and should be reviewed as a
file diff.

### `~/.smithy/config.toml`

These are correctly wrapper-config-backed:

| Key | Verdict |
| --- | --- |
| `default_runtime` | File-backed wrapper preference. |
| `default_workflow` | File-backed wrapper default. |
| `symphony_binary` | File-backed install path override. |
| `acknowledged_at` | File-backed local operator acknowledgement. |
| `[[repos]] slug/path/workflow/port` | File-backed daemon registry. |

### CLI Flags

| Flag | Verdict |
| --- | --- |
| `--logs-root <path>` | Correct process-launch override for launchd/file logging. |
| `--log-format file|stdout` | Added by this audit. `file` preserves existing disk logging; `stdout` leaves logs on the process stream for container-style operators. |
| `--port <port>` | Correct process-launch override for port binding. |
| `path-to-WORKFLOW.md` | Correct process-launch selection of config file. |

### Hardcoded Constants

| Constant | Location | Decision |
| --- | --- | --- |
| Claude Code default turn timeout `600_000` ms | `elixir/lib/symphony_elixir/runtime/claude_code/app_server.ex` | Env-overridable via `SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS`; invalid/non-positive values fall back to `600000`. |
| Codex turn/read/stall timeouts | `Config.Schema.Codex` | File-backed in `WORKFLOW.md`; no env override needed. |
| Polling interval `30_000` ms | `Config.Schema.Polling` | File-backed in `WORKFLOW.md`; no env override needed. |
| Agent concurrency/max turns/retry cap | `Config.Schema.Agent` | File-backed in `WORKFLOW.md`; no env override needed. |
| Retry base `10_000` ms and continuation delay `1_000` ms | `Orchestrator` | Intentionally fixed internal scheduling constants; retry cap is configurable. |
| Poll transition render delay `20` ms | `Orchestrator` | Intentionally fixed UI smoothing constant. |
| Workflow store poll `1_000` ms | `WorkflowStore` | Intentionally fixed hot-reload cadence. |
| Dashboard/status rendering windows and truncation limits | `StatusDashboard` | Intentionally fixed presentation constants. |
| Log rotation `10 MiB` x `5` files | `LogFile` | Existing application env override; not part of public v1 operator surface. |
| Linear HTTP connect timeout `30_000` ms and log truncation | `Linear.Client` | Intentionally fixed client safety defaults. |
| Static asset cache max age | `StaticAssetController` | Intentionally fixed web asset caching. |

## Factor I. Codebase

Verdict: compliant.

Rationale: Smithy wrapper and Symphony orchestrator live in one repository and
share a single versioned codebase. `wrapper/` and `elixir/` are separate Mix
apps, but they are built and reviewed together for this release line.

## Factor II. Dependencies

Verdict: compliant.

Rationale: Elixir dependencies are declared in each `mix.exs`/`mix.lock`, and
toolchain versions are declared through `mise.toml`. External commands such as
`git`, `gh`, `codex`, `claude`, `ssh`, and `launchctl` are runtime prerequisites,
not vendored dependencies.

## Factor III. Config

Verdict: compliant.

Rationale: Secrets are env vars. Deployment/workflow policy lives in
`WORKFLOW.md`. Local wrapper registry state lives in `~/.smithy/config.toml`.
The previous hardcoded Claude Code turn timeout now has the env fallback
`SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS` while retaining the default constant.
Other constants are either file-backed through `WORKFLOW.md` or documented above
as intentionally fixed implementation details.

## Factor IV. Backing Services

Verdict: compliant.

Rationale: Linear, GitHub, model runtimes, and SSH workers are attachable by
env/config rather than hardcoded in code. The Linear API endpoint is
configurable in `tracker.endpoint`; the default endpoint is appropriate for the
hosted Linear service.

## Factor V. Build, Release, Run

Verdict: compliant.

Rationale: Build is handled by Mix/mise. Release-time operator config is
externalized in `WORKFLOW.md` and `~/.smithy/config.toml`. Run is either
foreground `./bin/symphony WORKFLOW.md` or wrapper-generated launchd
supervision. This is adequate for the current prototype release model.

## Factor VI. Processes

Verdict: compliant.

Rationale: The orchestrator keeps in-memory running/retry/dashboard state, but
the durable source of truth is Linear plus workspace files and telemetry. On
boot, active work is rehydrated by polling Linear rather than by relying on
prior BEAM memory.

## Factor VII. Port Binding

Verdict: compliant.

Rationale: Symphony can self-bind the Phoenix observability endpoint using
`server.port` from `WORKFLOW.md` or the CLI `--port` override. The Smithy wrapper
stores per-repo ports in `~/.smithy/config.toml` and passes the port to the same
binary under launchd.

## Factor VIII. Concurrency

Verdict: compliant.

Rationale: Concurrency is controlled by `agent.max_concurrent_agents`,
`agent.max_concurrent_agents_by_state`, and
`worker.max_concurrent_agents_per_host`. Work is executed in BEAM tasks and can
be scaled by changing these config values and worker host topology.

## Factor IX. Disposability

Verdict: partial.

Rationale: Startup is fast. A local foreground measurement using a temporary
memory-tracker workflow reached the first completed poll in `80 ms`, excluding
Mix compilation. The documented SLO is:

- ideal: first poll in under `5s`
- acceptable: first poll in under `10s`

Crash recovery is acceptable for v1 because the orchestrator polls Linear on
boot and reconstructs active work from issue state. Shutdown is the gap:
`smithy daemon stop` delegates to `launchctl unload`, and the OTP tree/task
supervisor will terminate workers, but there is no explicit documented choice
between draining in-flight turns and terminating them immediately. Follow-up
PER-171 covers the shutdown/drain contract and validation.

## Factor X. Dev/Prod Parity

Verdict: compliant.

Rationale: Dev and prod both invoke the same Symphony binary with a
`WORKFLOW.md` file. Launchd adds supervision, captured env vars, log routing,
and a port from the wrapper registry, but it does not use a different code path
for polling or dispatch. Both currently target the same Smithy Engineering
Linear project; a separate dev project is not recommended for v1 because it
would reduce fidelity for the harness workflow.

## Factor XI. Logs

Verdict: partial.

Rationale: Existing macOS operation routes process stdout/stderr to
`~/.smithy/logs/<slug>/stdout.log` and `stderr.log` through launchd, while
Symphony application logs use the rotating disk handler under `--logs-root`.
That is operationally useful but not pure 12-factor streaming. This audit adds
`--log-format stdout`, which disables the rotating disk handler and keeps logs
on stdout for container-style operators. Telemetry JSONL remains an append-only
event store under `~/.smithy/telemetry/<slug>/<date>.jsonl`; it is treated as
telemetry persistence, not the primary process log.

## Factor XII. Admin Processes

Verdict: compliant.

Rationale: One-off admin tasks such as `smithy acknowledge`, `smithy add-repo`,
`smithy remove-repo`, `smithy status`, `smithy dashboard`, and `smithy logs`
run against the same wrapper code and config file as the daemon path. They do
not require a separate admin codebase.

## Violations And Disposition

| Finding | Disposition |
| --- | --- |
| Claude Code turn timeout was a hardcoded `600_000` ms default | Fixed inline with `SYMPHONY_CLAUDE_CODE_TURN_TIMEOUT_MS` fallback. |
| No stdout-streaming operator mode for Symphony application logs | Fixed inline with `--log-format stdout`; default remains `file`. |
| Disposability shutdown/drain semantics are not explicit or tested | Follow-up PER-171 filed in Backlog, related to PER-163. |

## Validation Evidence

- `mix test test/symphony_elixir/cli_test.exs test/symphony_elixir/runtime/claude_code/app_server_test.exs test/symphony_elixir/log_file_test.exs`
- `make -C elixir all`
- Boot measurement: `mix run --no-start` with a temporary memory-tracker workflow
  produced `boot_to_first_poll_ms=80`.
- Manual doc check: every 12-factor section above includes a verdict and
  rationale.
