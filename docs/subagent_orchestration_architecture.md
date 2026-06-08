# Subagent Orchestration Architecture

This document describes the architectural changes implemented to support high-performance, strictly isolated LLM execution within the `hermes_beam` agent framework, adhering strictly to Rich Hickey's principles of decomplecting state and time.

## The Gap

Previously, LLM execution and API interaction block the primary UI/State event loop, or require heavy threading inside the Gleam/BEAM runtime, which complects process state with unpredictable network latency. 

## The Solution: Local cmux over Unix Domain Sockets

We solved this by establishing a pure dataflow boundary via local Unix Domain Sockets (`.sock`).

1. **Subagent Supervisor (Gleam):** 
   - Uses native Erlang `gen_tcp` bindings (`uds_native.erl`) to establish an ephemeral socket.
   - Monitors an `intent_loop` listening to pure Gleamdb Datoms (e.g. `llm_request`, `spawn_worker`).
   - Spawns independent Clojure/Babashka worker binaries, injecting secrets locally over the UDS boundary.

2. **Subagent Worker (Babashka):**
   - Headless script (`worker.clj`) natively multiplexes JSON-RPC commands on the channel.
   - Executes LLM inference out-of-band, immune to Erlang's strict scheduler limitations.
   - Streams `telemetry` (heartbeat, memory footprint) recursively back into the channel.

3. **Reactive React UI (TUI):**
   - Telemetry from Babashka hits the Supervisor.
   - Supervisor maps the payload into a `Datom` and pushes it onto the `datom_subj`.
   - `tui_gateway.gleam` converts the Datom into a standard `hermes.broadcast` event.
   - The Vite frontend (`ChatSidebar.tsx`) parses the telemetry natively, surfacing real-time stats directly beside the PTY context.

## Rich Hickey Tradeoffs
By treating subagents as distinct POSIX processes, we maximize fault-tolerance and pure functional boundaries, at the cost of managing the lifecycle of physical `.sock` file descriptors. The result is unparalleled rendering performance in the primary CLI thread.
