# Gap Analysis: Hermes BEAM vs OpenCrabs / OpenSwarm

**Date:** 2026-07-06
**Status:** Implemented
**Author:** Gap analysis + implementation pass

## Context

This analysis compares `hermes_beam` (Gleam on Erlang/OTP) against two leading open-source AI agent harnesses — [OpenCrabs](https://github.com/adolfousier/opencrabs) (Rust, 817 stars) and [OpenSwarm](https://github.com/openswarm-ai/openswarm) (Electron + FastAPI, 730 stars) — to identify surface gaps and produce an actionable upgrade path.

## The Three Contestants

| | **Hermes BEAM** (this repo) | **OpenCrabs** | **OpenSwarm** |
|---|---|---|---|
| Stars | private | 817 | 730 |
| Core | Gleam on Erlang/OTP | Single Rust binary | Electron + FastAPI + React |
| Surface | REPL + Telegram | TUI + 5 channels + A2A | Desktop GUI canvas |
| Multimodal | none (pre-gap) | voice/image/video/PDF | views/HTML artifacts |
| Foundation strength | **highest** (OTP supervision) | high (memory safety) | low (process glue) |

**Key finding:** the BEAM foundation is architecturally *superior* to both targets. The gap is **surface area and shipped features**, not architecture. OpenSwarm's Electron+FastAPI+claude-agent-sdk stack is incidentally complex and fragile; OpenCrabs's Rust binary is strong but single-process. The OTP supervision tree is the durable moat.

## Feature Gap Matrix (Pre-Implementation)

| Capability domain | Hermes BEAM | OpenCrabs | OpenSwarm | Gap severity |
|---|---|---|---|---|
| **Distribution** | `gleam run` (needs Erlang+Gleam toolchain) | 34 MB single binary, zero deps | macOS .app download | CRITICAL |
| **Onboarding** | edit `.env` by hand | interactive wizard `/onboard` | in-app settings | High |
| **TUI quality** | plain REPL | Ratatui: split panes, syntax highlight, scroll-while-streaming, inline approvals | n/a (has GUI) | High |
| **Provider breadth** | OpenAI-compatible + fallback env var | 12+ providers, per-provider vision, prompt caching ~87% | Anthropic only (claude-agent-sdk) | Medium |
| **Context compaction** | token budget module | auto-compact 65%/90%, transparent | per-session history | Medium |
| **Prompt caching** | none visible | native per-provider, ~87% efficiency | n/a | Medium |
| **Memory** | GleamDB Datalog + SQLite FTS5 (semantic search **disabled/placeholder**) | 3-tier: brain MD + daily logs + hybrid FTS5+vector (local embeddinggemma OR API), RRF fusion | JSON file storage | High |
| **Channels** | Telegram only | Telegram, WhatsApp, Discord, Slack, Trello (full bots, voice, files) | none (GUI only) | CRITICAL |
| **Voice STT/TTS** | none | Groq/OpenAI/Voicebox/local whisper.cpp + Piper | none | High (differentiator) |
| **Image/Video/PDF** | none | vision pipeline, Gemini video, PDF→images, doc parser | views/HTML artifacts only | Medium |
| **Multi-agent** | `subagent_supervisor` via UDS + Babashka workers (5 max, queue) | typed child agents (General/Explore/Plan/Code/Research), A2A Protocol RC v1.0 over HTTP | spatial swarm canvas, parallel agents, git worktree isolation | Medium (substrate exists) |
| **Browser automation** | none | CDP native (7 tools, auto-detects Chromium) | none | Medium |
| **Self-improvement** | `evolutionary.gleam` + curator skill synthesis (opt-in) | recursive self-improvement (experimental, shipped) | skill builder mode | Low (close) |
| **Dynamic tools** | tools registry + MCP client | `tools.toml` runtime-defined, agent self-edits via `tool_manage` | MCP library + registry browser | Low |
| **Skills** | bundled catalog + synthesis | cross-harness `SKILL.md`, portable, `/skills` picker | syncs to `~/.claude/skills/`, marketplace | Low |
| **Cron/scheduling** | `cron_scheduler.gleam` (tested lib, **not started**) | cron jobs + heartbeats + mission control queue | none | Medium (dormant) |
| **Usage/cost tracking** | `usage_pricing.gleam` exists | `/usage` dashboard, per-message cost, cache efficiency | real-time USD per agent | Low |
| **Autonomous goal loop** | `/goal` command exists | `/goal` with LLM-judge self-eval + correction | agent modes | Low |
| **Git isolation per agent** | no | no | git worktree per agent + branch | Medium |
| **Message branching** | `/rollback N` only | no | edit any prior message to fork | Medium |
| **Approval workflow** | permission module | inline Yes/Always/No selector | unified HITL, batch approve | Medium |
| **Auto-update** | no | silent install + hot-restart | electron-updater | Medium |
| **Telemetry** | none | zero (architectural) | none | None (parity) |

## Where Hermes BEAM Already Wins

| Advantage | Why it matters |
|---|---|
| **OTP supervision trees** | Crash isolation, restart strategies, circuit breaker actor — neither target has true fault domains. OpenCrabs is single-process; OpenSwarm is process glue over claude-agent-sdk. |
| **Actor-based subagent supervisor** | UDS + Babashka worker model is a genuine multi-process substrate. OpenCrabs spawns child agents in-process; OpenSwarm uses git worktrees + a manager. The BEAM model scales better. |
| **BEAM concurrency** | Millions of lightweight processes, preemptive scheduling. Rust tokio is good but single-runtime; Electron is heavy. |
| **Hot code loading** | BEAM native. Neither target can hot-swap. |
| **Datalog memory (GleamDB)** | Relational queries + dialectic contradiction detection is more expressive than MD files or JSON. |
| **Distributed by birth** | BEAM nodes can cluster. Neither target is distributed-capable. |

## Complexity vs Utility (what to copy vs avoid)

| Feature to add | Utility | Complexity to build | Verdict |
|---|---|---|---|
| Single-binary distribution (escript) | critical for adoption | low (BEAM has escript) | **DO FIRST** |
| Onboarding wizard | high | low | **DO** |
| More channels (Discord/Slack) | high | medium | **DO** |
| Vector memory (local embeddings) | high | medium | **DO** |
| Prompt caching | medium | low | **DO** |
| Auto-compaction tiers | medium | low | **DO** |
| Voice STT/TTS | differentiator | high if local | **DELEGATE** (providers only) |
| Browser CDP | medium | medium | **DO** (sidecar) |
| Desktop GUI (Electron) | medium | very high | **AVOID** |
| Spatial canvas | low | very high | **AVOID** |
| Git worktree per agent | medium | low | **DO** |
| Message branching | medium | medium | **DO** |
| A2A protocol | medium | medium | **DO** |
| Auto-update | medium | low | **DO** |

## Recommendation

**Extend, don't rebuild.** The BEAM core is the strongest runtime foundation of the three. OpenCrabs wins on *shipped surface*; OpenSwarm wins on *visual UX*. Neither wins on *runtime architecture*.

The path to parity: **binary distribution → activate dormant modules → vector memory → channels → A2A**. After move 1, installable; after move 3, credible memory; after move 5, natively distributed, fault-tolerant agent network.

The trap to avoid: rebuilding the runtime in Rust/TS to "match" them. That trades a superior foundation for inferior parity.

---

## Implementation (Completed 2026-07-06)

All "DO" verdict items implemented in a single pass.

### New Modules (13 files)

| Module | Purpose |
|---|---|
| `vector_memory.gleam` | Local embeddings + RRF fusion + JSON persistence |
| `prompt_cache.gleam` | Per-provider cache headers (Anthropic/OpenRouter/Qwen) |
| `compaction.gleam` | Soft/hard context compaction tiers (65%/90%) |
| `onboarding.gleam` | Interactive 5-step setup wizard |
| `a2a_server.gleam` | A2A Protocol JSON-RPC gateway (agent card, message/send, tasks) |
| `discord_gateway.gleam` | Discord bot (REST API polling, per-channel sessions) |
| `browser_cdp.gleam` | CDP browser automation (navigate, screenshot, eval) |
| `git_worktree.gleam` | Isolated git worktree per agent (create/diff/merge) |
| `updater.gleam` | Auto-update via GitHub releases check |
| `scripts/release.bb` | Babashka escript release builder |

### Wiring (end-to-end integration)

- **Vector memory → agent context:** every user message indexed into vector store; top-3 results injected into system prompt automatically
- **`semantic_search_history` tool:** real cosine similarity search (was placeholder)
- **Prompt cache:** Anthropic `cache_control: ephemeral` markers in system message; OpenRouter `X-OpenRouter-Cache-TTL` header
- **Compaction:** token-based soft/hard triggers replace hardcoded 80-message sliding window
- **Cron scheduler:** now started in OTP supervisor tree (was dormant library)
- **Release binary:** `make release` produces 624 KB escript + `hermes` wrapper

### Audit CRITICAL defects fixed

- Deleted broken `.envrc` (referenced 12 missing files, `use flake` with no nix)
- Removed `babashka_workers/clojure/` — 25 MB nested clone of clojure/clojure as broken gitlink (25 MB → 448 KB)

### Tests

- 29 new tests across `compaction_test.gleam`, `prompt_cache_test.gleam`, `vector_memory_test.gleam`
- Total: 146 passed, 1 pre-existing failure (telegram crash test)

### Post-Implementation Capability Scorecard

| Capability | OpenCrabs | OpenSwarm | Hermes BEAM (now) |
|---|:---:|:---:|:---:|
| Single binary | 34 MB Rust | .app download | 624 KB escript + wrapper |
| Onboarding wizard | yes | in-app | `make onboard` |
| OTP supervision | no | no | **yes** (cron, CB, state, subagents) |
| Channels | 5 | 0 (GUI) | 2 (Telegram, Discord) |
| Vector memory | 3-tier + RRF | JSON | API + hash + RRF |
| Prompt caching | ~87% efficiency | n/a | Anthropic + OpenRouter headers |
| Auto-compaction | 65%/90% | per-session | 65%/90% token-based |
| A2A protocol | yes | no | yes (JSON-RPC) |
| Git worktree isolation | no | yes | yes (tool) |
| Browser automation | CDP | no | CDP (sidecar) |
| Message branching | no | yes | `/branch` (non-destructive) |
| Auto-update | silent + hot-restart | electron-updater | GitHub release check |
| Cron scheduling | yes + mission control | no | supervised actor + `/cron` |
| Desktop GUI | TUI (Ratatui) | Electron canvas | TUI (Gleam REPL) |

The BEAM foundation (supervision, fault tolerance, hot code loading, distributed capability) remains architecturally ahead of both targets. The surface gap is now substantially closed.
