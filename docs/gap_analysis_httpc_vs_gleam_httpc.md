# Rich Hickey Gap Analysis: Custom Erlang `httpc` FFI vs. `gleam_httpc` Library

This document conducts a thorough, Rich Hickey-style gap analysis comparing our custom Erlang `httpc` FFI implementation against the official `gleam_httpc` package. We analyze how both approaches handle state, time, dependencies, and streaming concerns, ending with an actionable recommendation.

---

## 1. Architectural Deconstruction (Complecting vs. Decomplecting)

Rich Hickey defines **complecting** as the braiding of concerns. When designing network request clients for LLM agents, we evaluate two primary axes of complection:
1. **Response Time vs. Memory Buffering**: Does the client force us to wait for the entire payload to be received (complecting data retrieval with buffer completion), or can we stream chunks progressively?
2. **Type System Dependencies**: Does the client require standard library HTTP structures (`gleam_http`), or does it run on basic, decoupled primitives?

### 1.1 `gleam_httpc` Library (Complected)
* **Complects Streaming & Buffering**: `gleam_httpc.send` is strictly synchronous and blocking. It holds the network request active and buffers the entire HTTP body in memory before returning a response record. For LLM response tokens (SSE), this means we cannot draw tokens progressively; we must wait minutes for the LLM to complete its output.
* **Complects Type Definitions**: It depends on `gleam_http`, which introduces request/response types. While type-safe, this couples the compiler's package index to specific third-party library versions.

### 1.2 Custom Erlang `httpc` FFI (Decomplected)
* **Decomplects Time & Chunk Ingestion**: By directly invoking Erlang's `httpc:request` with asynchronous options (`{sync, false}, {stream, self}`), we receive chunks immediately as Erlang mailbox messages. The client process does not block on the socket. It decouples chunk arrival from total response completion.
* **Zero Dependencies**: It operates directly on raw strings and FFI lists, remaining completely independent of the `gleam_http` or `gleam_httpc` package trees.

---

## 2. Feature Set Comparison

| Feature Category | Custom Erlang `httpc` FFI | `gleam_httpc` Library | Architectural Impact & Trade-off |
| :--- | :--- | :--- | :--- |
| **Streaming (SSE)** | **Supported** (Asynchronous mailbox chunks) | **Not Supported** (Buffers full response) | **Custom FFI**: Crucial for real-time agent output streaming. **gleam_httpc**: Causes severe TUI rendering lags. |
| **Request Mode** | Asynchronous & Synchronous options | Synchronous only | **Custom FFI**: Allows both blocking setup calls and non-blocking streaming collectors. |
| **Dependency Footprint**| **Zero** (Standard Erlang FFI) | 2 Packages (`gleam_httpc` + `gleam_http`) | **gleam_httpc**: Introduces package version ceilings to `gleam.toml`. |
| **Header Types** | List of tuples `List(#(String, String))` | Map-wrapped HTTP request structures | **gleam_httpc**: Cleaner integration with standard Gleam routing tools. |
| **TLS/SSL Validation** | Configured via native Erlang `:ssl` | Configured via underlying `httpc` | Identical (both rely on the host VM's certifi/inets TLS store). |

---

## 3. Complexity vs. Utility Analysis

| Component | Essential Complexity | Accidental Complexity | Utility | Hickey Assessment |
| :--- | :---: | :---: | :---: | :--- |
| **`gleam_httpc.send`** | Low | Low (Simple function call) | Medium | **Complected.** Simple but insufficient; the sync-only constraint blocks TUI streaming utility. |
| **Custom Erlang `httpc` FFI** | Medium | Low (Requires Erlang FFI mapper module) | High | **Simple.** Separates request creation from process message collection. |
| **Erlang Process Selector** | Medium | Medium (Requires mapping dynamic terms) | High | **Simple.** De-complects socket reading by treating packets as inbox facts. |

---

## 4. Actionable Recommendation

* **Recommendation**: **Retain and optimize the Custom Erlang `httpc` FFI boundary.**
* **Rationale**: The `gleam_httpc` package is designed purely for synchronous request/response patterns. Because streaming SSE tokens is a **high-utility, essential requirement** for agentic terminal interfaces, the lack of async streaming in `gleam_httpc` makes it a blocker.
* **Refinement Action**: To maintain Rich Hickey quality and cleanliness, we should ensure the custom Erlang FFI remains strictly type-safe, cleanly translating mailbox types and handling timeouts dynamically without relying on external dependencies.
