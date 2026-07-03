# Security Guidance

Hermes can execute local tools, launch optional MCP processes, and expose gateway integrations. Treat the runtime host as sensitive infrastructure.

## Secrets

- Do not commit real `.env` files, API keys, Telegram tokens, OAuth credentials, or private keys.
- Prefer a secret manager or protected service environment over plaintext files.
- If a `.env` file is used, store it under `HERMES_HOME` with permissions limited to the service user.
- Rotate `HERMES_API_KEY`, provider fallback keys, and `HERMES_TELEGRAM_TOKEN` after accidental disclosure.

## Runtime Isolation

- Run Hermes as a dedicated non-root user.
- Use a dedicated, writable `HERMES_HOME` rather than a developer home directory.
- Limit filesystem access through container, VM, or OS-level sandboxing where possible.
- Back up runtime state separately from secrets.

## Tool Execution

Hermes strongly prefers Babashka (`bb`) for scripting and worker support. Production hosts should install `bb` explicitly and validate it with `make doctor`.

When enabling worker shell allowlists, configure `HERMES_WORKER_SHELL_ALLOWLIST` with only the executables required for your deployment. Keep optional MCP commands narrow and pinned to known binaries.

## Telegram Gateway

`HERMES_TELEGRAM_TOKEN` is required for gateway mode. Before exposing the gateway beyond trusted local testing:

- Configure `HERMES_TELEGRAM_ALLOWED_USERS` or `GATEWAY_ALLOWED_USERS` with trusted Telegram user IDs/usernames.
- Keep `HERMES_GATEWAY_LOCK_PORT` stable per host to prevent duplicate gateway instances.
- Monitor `HERMES_HOME/logs` for unexpected gateway activity.
- Rotate the bot token if the allowlist was absent during public exposure.

## MCP Integration

`HERMES_MCP_CMD` is optional. If enabled, Hermes starts the command as a child process. Use absolute paths or predictable service `PATH` configuration, pin command versions, and avoid commands that read untrusted project files unless intentionally sandboxed.

## Optional Subsystems

Leave optional features disabled unless the deployment explicitly needs them:

- `HERMES_ENABLE_SKILL_SYNTHESIS=true` allows the REPL exit hook to write synthesized skills under `HERMES_HOME/skills`.
- `HERMES_ENABLE_SEMANTIC_SEARCH=true` exposes a placeholder semantic-search tool; do not enable it for production policy claims until an embedding index is wired and reviewed.
- `HERMES_MEMORY_BACKEND` enables memory context retrieval. External backends (`honcho`, `mem0`, `supermemory`) send context to third-party APIs; `gleamdb` stays local.
- API server and cron scheduler surfaces are disabled/not started by current CLI entry points.

## Validation

Run:

```sh
make doctor
```

Treat doctor errors as deployment blockers. Treat warnings as required review items for production, especially missing credentials, missing Babashka, configured-but-unresolved MCP commands, and missing Telegram allowlists.
