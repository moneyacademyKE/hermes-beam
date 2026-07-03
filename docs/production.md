# Production Deployment

Hermes BEAM is the production runtime for this repository. Deploy from `hermes_beam/` with Erlang/OTP, Gleam, and Babashka available on the host.

## Prerequisites

- Erlang/OTP 26 or newer.
- Gleam 1.2 or newer.
- Babashka (`bb`) for worker-side Datalog and subagent support.
- A writable `HERMES_HOME` for runtime state, logs, skills, and local `.env` loading.
- LLM credentials via `HERMES_API_KEY`, `OPENROUTER_API_KEY`, or `OPENAI_API_KEY` unless mock completion mode is intentional.

## Configuration

Start from `.env.example` and place production secrets outside git. Hermes loads `.env` from `HERMES_HOME`, and process environment variables override host-level service configuration naturally.

Recommended baseline:

```env
HERMES_HOME=/var/lib/hermes
HERMES_API_KEY=...
HERMES_BASE_URL=https://openrouter.ai/api/v1
HERMES_MODEL=openai/gpt-4o-mini
HERMES_TOKEN_BUDGET=200000
HERMES_STREAM_TIMEOUT_MS=120000
HERMES_ENABLE_SKILL_SYNTHESIS=false
HERMES_ENABLE_SEMANTIC_SEARCH=false
HERMES_MEMORY_BACKEND=
```

For Telegram gateway deployments, also configure:

```env
HERMES_TELEGRAM_TOKEN=...
HERMES_TELEGRAM_ALLOWED_USERS=123456789,@trusted_user
HERMES_GATEWAY_LOCK_PORT=8765
```

For optional MCP integration, set `HERMES_MCP_CMD` to the command Hermes should launch. Validate that the first executable in the command is installed and available in `PATH` for the service user.

Optional subsystems are disabled by default to avoid half-integrated runtime surfaces:

- Skill synthesis only runs on REPL exit when `HERMES_ENABLE_SKILL_SYNTHESIS=true`.
- `semantic_search_history` is hidden from tool schemas unless `HERMES_ENABLE_SEMANTIC_SEARCH=true`; the current implementation is a placeholder without a persisted embedding index.
- Memory injection is disabled unless `HERMES_MEMORY_BACKEND` is set to `gleamdb`, `honcho`, `mem0`, or `supermemory`.
- OpenAI-compatible API server mode is disabled; `--server` exits without listening.
- The cron scheduler module is available for tests/library use, but no production CLI or supervisor path starts it.

## Validation

Run the doctor before starting production services:

```sh
make doctor
```

The doctor checks Erlang/Gleam prerequisites through the Makefile and validates Hermes runtime directories, credential presence, Babashka availability, optional MCP command executability, and Telegram token/allowlist hints through the Gleam CLI.

Run tests before promotion:

```sh
make test
make worker-test
```

## Operation

Interactive runner:

```sh
make run
```

Telegram gateway:

```sh
make telegram
```

Use a process manager such as systemd, launchd, Docker, or an equivalent supervisor. Configure a fixed `HERMES_HOME`, a restricted service user, restart policy, log collection for `HERMES_HOME/logs`, and environment injection from a secret manager or protected env file.

## Data And Backup

Back up `HERMES_HOME` if session history, opt-in synthesized skills, or local state must survive host replacement. At minimum, include:

- `state.db`
- `skills/`
- `logs/` when operational audit trails are required
- `.env` only through the secure secret-backup path, not general application backups

## Upgrade Checklist

1. Stop the running service.
2. Deploy the new repository revision or release artifact.
3. Run `make doctor` with the production environment loaded.
4. Run `make test` when toolchain and time budget allow.
5. Start the service and verify logs under `HERMES_HOME/logs`.
