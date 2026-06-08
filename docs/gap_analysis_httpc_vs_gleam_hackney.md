# Rich Hickey Gap Analysis: Custom Erlang `httpc` FFI vs. `gleam_hackney` Library

This document performs a thorough and comprehensive Rich Hickey-style gap analysis comparing our custom Erlang `httpc` FFI implementation against the popular Erlang HTTP client wrapper library **`gleam_hackney`**.

Following Rich Hickey's principles, we analyze the essential simplicity of each stack by investigating dependency complection, connection pooling overhead, streaming capabilities, and VM runtime boundaries.

---

## 1. Architectural Deconstruction (Complecting vs. Decomplecting)

Rich Hickey defines simplicity as the absence of complection (braiding or intertwining of concerns). When evaluating HTTP clients on the Erlang BEAM VM, we analyze three forms of complection:
1. **Dependency Complection**: Does the client require third-party libraries and native compile steps, or does it run out-of-the-box on standard OTP runtimes?
2. **Response Time vs. Memory Buffering**: Does the client support non-blocking streaming (SSE), or does it force memory-buffering of response payloads?
3. **Connection Management**: How are sockets and pools managed across concurrent agent processes?

### 1.1 `gleam_hackney` / Hackney (Complected)
* **Dependency Complection**: Hackney is a third-party Erlang dependency that complects our build pipeline. It pulls in a deep chain of transitive Erlang dependencies (`mimerl`, `certifi`, `ssl_verify_fun`, `idna`, `metrics`). This increases security audit overhead and compile-time latency.
* **Sync-Only Gleam Wrapper**: The `gleam_hackney` Gleam wrapper only exposes synchronous `send`/`send_bits` endpoints. To perform SSE streaming (necessary for LLMs), we would have to bypass the wrapper entirely and write a custom Erlang FFI boundary to Hackney's native Erlang API.
* **Connection Pooling**: Hackney utilizes a dedicated, stateful connection pool supervisor (`hackney_pool`). While highly performant for concurrent socket reuse, it introduces stateful pool management, which complects process supervision.

### 1.2 Custom Erlang `httpc` FFI (Decomplected)
* **Zero Dependencies**: Relies entirely on the native `inets` application built directly into Erlang/OTP. It does not introduce any transitive dependencies or compilation overhead, keeping the project footprint completely simple and clean.
* **Decomplected Streaming**: Our custom FFI boundary invokes native `httpc` async streams (`{sync, false}, {stream, self}`), routing chunk events directly to the caller's process mailbox. It decouples network socket collection from memory buffering.
* **Simple Socket Isolation**: Each request is handled by a standard BEAM process supervisor under `inets`, avoiding the need to configure and supervise third-party connection pool processes.

---

## 2. Feature Set Comparison

| Feature Category | Custom Erlang `httpc` FFI | `gleam_hackney` Library | Architectural Impact & Trade-off |
| :--- | :--- | :--- | :--- |
| **Streaming (SSE)** | **Supported** (Asynchronous mailbox chunks) | **Not Supported** (Buffers full response) | **Custom FFI**: Crucial for real-time agent output streaming. **gleam_hackney**: Synchronous-only in the Gleam API. |
| **Dependency Footprint**| **Zero** (Standard Erlang standard library) | 6 Erlang libraries (transitive tree) | **gleam_hackney**: Increases compiler footprint and audit surface. |
| **Connection Pooling** | Simple (Built-in global pooler) | **Advanced** (`hackney_pool` manager) | **Hackney**: Superior connection reuse and multiplexing under high load. |
| **API Type Definitions** | Decoupled (primitives and lists) | Complected (coupled to `gleam_http`) | **gleam_hackney**: Integrates with standard Gleam HTTP records, but locks versioning. |
| **Proxy & Redirects** | Basic configuration options | Comprehensive proxy/redirect engines | **Hackney**: Extremely mature engine for routing through custom tunnels. |

---

## 3. Complexity vs. Utility Analysis

| Component | Essential Complexity | Accidental Complexity | Utility | Hickey Assessment |
| :--- | :---: | :---: | :---: | :--- |
| **`gleam_hackney`** | Low | Medium (Deep dependency tree) | Medium | **Complected.** The dependency overhead is high, while the Gleam wrapper lacks streaming utility. |
| **Custom Erlang `httpc` FFI** | Medium | Low (Single FFI boundary module) | High | **Simple.** Clean, zero-dependency bindings that natively support async SSE streaming. |
| **Hackney Erlang Engine** | High | High (Supervisor pools and sockets) | High | **Powerful but Complex.** Excellent for massive socket pools, but introduces state management. |

---

## 4. Actionable Recommendation

* **Recommendation**: **Retain the Custom Erlang `httpc` FFI boundary.**
* **Rationale**: The official `gleam_hackney` library only exposes synchronous endpoints, meaning it cannot stream LLM tokens. While the underlying Erlang `hackney` engine does support streaming, importing it introduces 6 external Erlang dependencies, violating the goal of keeping the codebase simple and dependency-free.
* **Decision**: Because Erlang's standard library `inets` (`httpc`) is built-in and fully supports async streaming, our custom FFI boundary provides the highest utility with zero external dependency complexity.
