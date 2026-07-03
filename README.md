# Hermes BEAM

Hermes BEAM is the primary runtime in this repository: a Gleam application on Erlang/OTP for supervised, stateful AI-agent execution.

The active implementation lives in `hermes_beam/`. Other directories are support material, optional skills/MCP manifests, examples, historical analysis, or operational documentation.

## Focus

- `hermes_beam/` contains the BEAM runtime, tests, gateway entry points, actors, and worker orchestration.
- `babashka_workers/` contains the Babashka worker sidecar used by subagent supervision.
- `docs/` contains gap analyses, roadmap notes, and architecture walkthroughs for the BEAM migration.
- `skills/` and `optional-mcps/` are bundled capability catalogs, not the runtime core.

## Requirements

- Erlang/OTP 26 or newer
- Gleam 1.2 or newer
- Babashka for worker-side Datalog/subagent support
- `make` for the top-level command shortcuts

## Quick Start

```sh
cp .env.example .env
make build
make test
make doctor
make run
```

Telegram gateway mode requires `HERMES_TELEGRAM_TOKEN`:

```sh
make telegram
```

## Command Reference

Top-level commands are defined in `Makefile` and documented in `COMMANDS.md`.

- `make build` builds `hermes_beam`.
- `make test` runs the Gleam test suite.
- `make run` starts the interactive Hermes BEAM runner.
- `make telegram` starts the Telegram gateway.
- `make worker-test` runs the worker/supervisor-focused tests.
- `make doctor` checks required local tools, Hermes home directories, credentials, optional MCP command configuration, Babashka availability, and Telegram gateway hardening hints.

Retired Python/Node packaging, Nix, old Docker Compose, website deployment, PyPI/uv, Windows installer, WhatsApp bridge, and scratch Gleam surfaces have been removed from the repository. New runtime work should stay subordinate to `hermes_beam/` unless it has an explicit support plan.

## Runtime Configuration

Use `.env.example` as the concise list of supported Hermes BEAM environment variables. The application loads `.env` from `HERMES_HOME` when configured, and shell-exported variables also work.

Minimum useful variables:

```env
HERMES_API_KEY=...
HERMES_BASE_URL=https://openrouter.ai/api/v1
HERMES_MODEL=openai/gpt-4o-mini
HERMES_HOME=~/.hermes
```

Production setup and operational hardening are documented in `docs/production.md`; credential handling and gateway security guidance are documented in `docs/security.md`.

Optional subsystems are off unless explicitly configured:

- `HERMES_ENABLE_SKILL_SYNTHESIS=true` enables REPL-exit synthesis of `SKILL.md` files.
- `HERMES_ENABLE_SEMANTIC_SEARCH=true` exposes the placeholder `semantic_search_history` tool schema; leave it unset until a persisted embedding index is available.
- `HERMES_MEMORY_BACKEND=gleamdb|honcho|mem0|supermemory` selects a memory context backend; unset disables memory injection.
- `--server` is intentionally disabled and exits without starting an API listener.
- `cron_scheduler` is a tested library module, not started by any CLI or supervisor entry point.

## Roadmap Context

The stabilization roadmap is tracked in `docs/walkthrough_hermes_beam_roadmap.md` and adjacent `docs/gap_analysis_*` files. Repository-level maintenance should keep Hermes BEAM as the clear default and avoid reintroducing high-complexity non-BEAM entry points.

## License

MIT. See `LICENSE` when present in this checkout.
