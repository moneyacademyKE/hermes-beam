# Hermes BEAM — Learnings

> Living document. Updated from dogfooding, debugging, and architectural sessions.
> Follow the Rich Hickey path: identity through time, values not places, decomplection.

---

## Architecture Learnings

### Gleam OTP Actor Model
- **Pattern**: `StateActor` wraps a `Subject(Message)` with an opaque type. All state mutations go through message passing — no shared mutable state.
- **Lesson**: Use `actor.call` with a timeout for synchronous operations; use `process.send` for fire-and-forget. Keep `handle_message` a pure dispatch function.
- **Lesson**: Gleam's exhaustive pattern matching catches missing message arms at compile time — critical for actor safety.

### BEAM Supervisor Auto-Heal
- The UDS accept loop calls `accept_uds` → on failure, logs "Accept loop failed" and sleeps 1s then retries.
- **Lesson**: Auto-heal loops should always be tail-recursive (no stack growth) and use `process.sleep` before retry to avoid tight spin loops.

### Erlang httpc Stream Mode — Critical Gotcha
- **Problem**: When `httpc:request` is used with `{stream, self}`, a non-200 response is delivered as a **complete tuple** `{ReqId, {{Version, Status, Phrase}, Headers, Body}}` — NOT as stream messages (`stream_start` → `stream` → `stream_end`).
- **Root cause**: Erlang delivers the complete response when it detects non-2xx, bypassing the streaming protocol.
- **Fix**: Always pattern-match for the complete-response tuple in `decode_http_message/2` BEFORE the stream message clauses.
- **Anti-pattern**: Relying on `stream_start` always arriving first.

### SSE Stream Error Propagation
- **Problem**: Empty streaming responses triggered a fallback non-streaming call — but if the error was auth/quota, that also failed. Result: 2+ minutes of silent hanging then `[No response from model]`.
- **Fix**: Return `__STREAM_ERROR__:<reason>` sentinel from `stream_and_collect` on `StreamError`/`StreamTimeout`. Detect in `agent_turn_loop` before calling fallback.
- **Pattern**: Sentinel strings are an effective escape hatch in functional pipelines where the return type is `String` and you can't change the type signature.

### Gleam Guard Limitation
- **Problem**: `case x { val if some_function(val) -> ...}` is **not allowed** in Gleam guards — only boolean operators and literals.
- **Fix**: Move the function call inside the branch body: `val -> { case some_function(val) { True -> ... False -> ... } }`.

### Recur Across Try in Babashka (SCI)
- **Problem**: Babashka/SCI does not allow `recur` inside a `try` block (`Cannot recur across try`).
- **Fix**: Capture the try result in a `let` binding, then `recur` outside the try: `(let [ok (try ... (catch Exception _ false))] (when ok (recur)))`.

---

## Performance Learnings

### Context Window Overflow on Long /goal Runs
- **Problem**: `history` is a list prepended on every turn. After 80+ messages on a long `/goal` run, the full context is sent on every API call → context overflow + high cost.
- **Fix**: Sliding window in `build_request_body` — trim to newest 60 msgs when `length(history) > 80`. System prompt is outside the window (always included).
- **Lesson**: The system message is the stable identity; the history is the mutable value. Decomplect them.

### Free-Tier Model Queue Latency
- **Problem**: `nex-agi/nex-n2-pro:free` on OpenRouter has a ~2-3 minute queue wait per response — well above the original 120s stream timeout.
- **Fix**: Made `receive_stream_chunk` timeout configurable via `HERMES_STREAM_TIMEOUT_MS` (default 300_000ms = 5 min).
- **Lesson**: Never hardcode network timeouts. Externalize to config/env. Free models have unbounded queue latency.

### Double API Call on Tool Responses
- **Problem**: Models that respond with tool_calls via SSE have no `content` field — streaming accumulator collects `""` → triggers non-streaming fallback → 2 API calls per tool turn.
- **Status**: Open. Requires SSE delta tool_call parsing (parse `tool_calls` array from streaming deltas, not just `content`).

---

## Observability Learnings

### Telemetry Through GleamDB Datoms
- Babashka workers emit telemetry as `Datom(entity, "telemetry", value)` over UDS → `intent_loop` prints and logs them.
- **Lesson**: Datoms are excellent for side-channel telemetry — they flow through the same reactive pipeline as data without coupling.

### Structured vs Unstructured Logging
- Currently using `log_event/1` which appends plain strings to `agent.log`.
- **Gap**: No structured trace format (no session ID, no timestamp in log entries, no severity). JSONL would enable grep/jq analysis.

---

## Resilience Patterns

### Exponential Backoff
- **Pattern**: `retry(Fun, MaxRetries, InitDelayMs, LastResult)` — call Fun, check if error is retryable (429/502/503/conn), sleep and double delay, recurse.
- **Erlang impl**: Use `timer:sleep(DelayMs)` between attempts. Keep the pattern pure: pass accumulated result as last arg for tail-call.
- **Lesson**: Always classify errors before retrying — don't retry 401/403 auth failures (they won't fix themselves).

### Crash Recovery with --resume
- **Pattern**: On startup, check argv for `--resume <session-id>`, load history + CWD from SQLite, restore into `AgentState`.
- **Lesson**: Resumability requires that all mutable state be externalized (SQLite) and that the in-memory agent state be reconstructible from it. This is the Rich Hickey "state as a value at a point in time" pattern.

### Duplicate Initialization Bug
- **Root cause**: `run_repl/0` was creating the MCP client twice (two `case` blocks both binding to `mcp_client_opt`). The second binding shadowed the first — two goroutines started.
- **Lesson**: In Gleam, `let` bindings shadow — silently. When refactoring long functions, trace all bindings.

---

## Babashka / Clojure Patterns

### Python Firewall
- `run_command` tool in `worker.clj` now uses `re-find #"(?i)\bpython\b"` to detect and block Python invocations.
- **Pattern**: Policy enforcement at the execution boundary, not the prompt layer. The prompt instructs, the tool enforces.

### bb_eval Tool
- Inline Clojure evaluation via temp file + `(p/sh "bb" path)` pattern.
- **Lesson**: Temp files are the right abstraction for passing multi-line code to bb subprocess. Always `(.delete tmp-file)` in `finally`.

### Docker → bb Fallback
- Check `docker-available?` first; if false, check `bb-available?`; if both false, return error string.
- **Pattern**: Graceful degradation chain. Never crash — return an informative error string that the LLM can act on.

---

## Rich Hickey Certifications

| Principle | Applied |
|---|---|
| Decomplect state from identity | `AgentState` is a pure value; `StateActor` holds the reference |
| Values not places | History is an immutable list; new turns create new lists |
| Simple made easy | REPL commands are pure case dispatches, no class hierarchy |
| Data > objects | Datoms (entity/attribute/value) flow through the whole system |
| No Python | Enforced at tool boundary, not just in prompts |
| Crash recovery | Externalized to SQLite; `--resume` reconstructs state from values |
