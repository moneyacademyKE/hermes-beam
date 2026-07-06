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
- Gleam 1.2 or newer (for development; not needed if using the release binary)
- Babashka for worker-side Datalog/subagent support
- `make` for the top-level command shortcuts

## Quick Start

### Option A: Onboarding wizard (recommended for first run)

```sh
make build
make onboard    # interactive 5-step setup wizard
make run        # start the REPL
```

### Option B: Manual configuration

```sh
cp .env.example .env
# Edit .env with your API key, model, and preferences
make build
make test
make doctor
make run
```

### Option C: Release binary (no Gleam toolchain needed on target)

```sh
make release    # builds a self-contained escript binary
./hermes        # run directly (requires only Erlang/OTP on the target)
```

## Gateways

```sh
make telegram   # Telegram bot gateway
make discord    # Discord bot gateway
make a2a        # A2A Protocol JSON-RPC server
```

Telegram gateway requires `HERMES_TELEGRAM_TOKEN`. Discord gateway requires `HERMES_DISCORD_TOKEN`.

## Command Reference

Top-level commands are defined in `Makefile` and documented in `COMMANDS.md`.

- `make build` builds `hermes_beam`.
- `make test` runs the Gleam test suite (146 tests).
- `make run` starts the interactive Hermes BEAM REPL.
- `make release` builds a self-contained escript binary.
- `make install` builds and installs the binary to `/usr/local/bin/hermes`.
- `make onboard` runs the interactive configuration wizard.
- `make telegram` starts the Telegram gateway.
- `make discord` starts the Discord gateway.
- `make a2a` starts the A2A Protocol server.
- `make worker-test` runs the worker/supervisor-focused tests.
- `make doctor` checks required local tools, Hermes home directories, credentials, optional MCP command configuration, Babashka availability, and gateway hardening hints.

### CLI Flags

```
hermes                  # Start interactive REPL (default)
hermes --onboard        # Run configuration wizard
hermes --doctor         # Run diagnostics
hermes --version        # Show version and update status
hermes --update         # Check for updates
hermes --telegram       # Start Telegram gateway
hermes --discord        # Start Discord gateway
hermes --a2a            # Start A2A Protocol server
hermes --resume <id>    # Resume a past session
```

### REPL Commands

```
/help            - Show available commands
/quit, /exit     - Close session
/model <name>    - Switch model (resets history)
/cwd <path>      - Switch working directory
/run <cmd>       - Execute shell command directly (bypasses LLM)
/file <path>     - Load prompt from file
/clear           - Clear conversation history
/sessions        - List recent sessions
/resume <id>     - Resume a past session
/rollback <n>    - Undo last N messages (destructive)
/branch <n>      - Fork from N messages ago (non-destructive)
/search <term>   - FTS5 keyword search across all sessions
/vsearch <q>     - Semantic vector search across memory
/goal <prompt>   - Run autonomous task until finished
/cron <cmd>      - Manage scheduled jobs (list|add|remove)
/usage           - Show token usage and budget
/onboard         - Run configuration wizard
```

## Runtime Configuration

Use `.env.example` as the concise list of supported Hermes BEAM environment variables. The application loads `.env` from `HERMES_HOME` when configured, and shell-exported variables also work.

Minimum useful variables:

```env
HERMES_API_KEY=...
HERMES_BASE_URL=https://openrouter.ai/api/v1
HERMES_MODEL=openai/gpt-4o-mini
HERMES_HOME=~/.hermes
```

### Subsystems

| Subsystem | Env Var | Default | Description |
|---|---|---|---|
| Skill synthesis | `HERMES_ENABLE_SKILL_SYNTHESIS` | false | Synthesize `SKILL.md` on REPL exit |
| Semantic search | `HERMES_ENABLE_SEMANTIC_SEARCH` | false | Vector search over conversation memory |
| Memory backend | `HERMES_MEMORY_BACKEND` | unset | `gleamdb`, `honcho`, `mem0`, or `supermemory` |
| Vector backend | `HERMES_VECTOR_BACKEND` | api | `api` (OpenAI embeddings), `hash` (local offline), `disabled` |
| Context window | `HERMES_CONTEXT_WINDOW` | 200000 | Token budget for auto-compaction |
| Compaction soft | `HERMES_COMPACTION_SOFT_PCT` | 65 | Soft trigger percentage |
| Compaction hard | `HERMES_COMPACTION_HARD_PCT` | 90 | Hard trigger percentage |
| Auto-update | `HERMES_AUTO_UPDATE` | false | Check GitHub releases on startup |
| A2A port | `HERMES_A2A_PORT` | 8080 | A2A Protocol server port |
| Discord token | `HERMES_DISCORD_TOKEN` | unset | Required for Discord gateway |
| Telegram token | `HERMES_TELEGRAM_TOKEN` | unset | Required for Telegram gateway |

### Active Subsystems

The following subsystems are now **active in the OTP supervision tree**:

- **Cron scheduler** — supervised actor with 10-second tick interval, `/cron` REPL commands for job management
- **Circuit breaker** — per-model failure tracking with configurable threshold and cooldown
- **Token budget** — supervised actor tracking token consumption across the session
- **Subagent supervisor** — UDS-based Babashka worker orchestration with auto-healing
- **State actor** — single-writer SQLite session store with FTS5 full-text search

### Auto-Compaction

Context is automatically compacted at two thresholds to prevent context window overflow:

- **65% (soft trigger):** background summarization of older messages
- **90% (hard trigger):** synchronous compaction before the next request

Both are configurable via `HERMES_COMPACTION_SOFT_PCT` and `HERMES_COMPACTION_HARD_PCT`.

### Prompt Caching

Prompt caching is automatically enabled for providers that support it:

- **Anthropic:** native `cache_control: ephemeral` markers on system prompt
- **OpenRouter:** `X-OpenRouter-Cache-TTL: 300` header
- **OpenAI / Qwen:** server-side caching (automatic, no config needed)

### Vector Memory

When `HERMES_ENABLE_SEMANTIC_SEARCH=true`, every user message is indexed into a local vector store. The `semantic_search_history` tool performs cosine similarity search, and relevant past context is automatically injected into the system prompt. Three backends:

- **`api`** — OpenAI `text-embedding-3-small` embeddings (default, requires API key)
- **`hash`** — local 128-dimension hash embeddings (offline, no API key needed)
- **`disabled`** — no vector indexing

Results can be fused with FTS5 keyword search via Reciprocal Rank Fusion (RRF).

### A2A Protocol

The A2A server implements the Agent-to-Agent Protocol RC v1.0 over JSON-RPC 2.0:

- `GET /.well-known/agent.json` — agent card (capabilities, skills, endpoints)
- `POST /` — JSON-RPC methods: `message/send`, `tasks/get`, `tasks/cancel`, `tasks/list`

This enables peer-to-peer agent communication with other A2A-compatible agents.

## Agent Tools

The agent has 8 built-in tools:

| Tool | Description |
|---|---|
| `run_command` | Execute shell commands (sandboxed) |
| `write_file` | Write content to files |
| `read_file` | Read file contents |
| `handoff_session` | Hand off context to subagents |
| `create_worktree` | Create isolated git worktree for parallel work |
| `diff_worktree` | Show uncommitted changes in a worktree |
| `browser_navigate` | Navigate browser to URL via CDP |
| `browser_screenshot` | Capture browser screenshot via CDP |

Plus `semantic_search_history` when enabled.

## Roadmap Context

The stabilization roadmap is tracked in `docs/walkthrough_hermes_beam_roadmap.md` and adjacent `docs/gap_analysis_*` files. Repository-level maintenance should keep Hermes BEAM as the clear default and avoid reintroducing high-complexity non-BEAM entry points.

## License

MIT. See `LICENSE` when present in this checkout.
