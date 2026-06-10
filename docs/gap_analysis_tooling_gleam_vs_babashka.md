# Gap Analysis: Gleam-Level vs. Babashka-Level Tooling Execution

> [!NOTE]
> **Post-Implementation Update (June 2026)**
> Since this gap analysis was performed, we implemented the recommendation to convert the Datalog Engine to the Babashka level by implementing a custom JVM-free micro-Datalog interpreter directly in `worker.clj`. The custom orchestrator-side `gleamdb.gleam` has been completely removed. Logical query execution (such as permissions checks and skill evolutionary loops) is now successfully delegated from Gleam to Babashka over CLI boundaries.

This document details how the Clojure/Babashka worker currently interacts with Gleam-level tooling, and evaluates which advanced tooling components would perform better if converted to run directly at the Babashka level instead.

---

## 1. Current UDS Socket Delegation Mechanism

In the hybrid architecture, the Babashka worker process behaves as a headless client running out-of-process. It interacts with the stateful Gleam core using the Unix Domain Socket (UDS) JSON-RPC bridge:

```
┌────────────────────────┐                    ┌────────────────────────┐
│  Gleam/BEAM Core       │                    │  Babashka Worker       │
│  - MCP Client          │                    │  - Local Shell Tools   │
│  - WASM Executor       │◄─── UDS Sockets ──►│  - LLM Reasoning Loop  │
│  - Datalog Registry    │   (JSON-RPC API)   │  - Dynamic Context     │
│  - State Actor         │                    │                        │
└────────────────────────┘                    └────────────────────────┘
```

### 1.1. Tool Resolution Flow
1. **Dynamic Tool Schemas**: During task initialization (`AcceptConnection`), the Gleam supervisor retrieves all dynamic tool schemas (from MCP, WASM, and core tools) using `hermes_agent.all_tool_schemas` and includes them in the `execute_task` parameter list.
2. **Tool Delegation**: When the LLM calls a tool:
   - If the tool is native to the worker (e.g. `run_command`, `bb_eval`), Babashka executes it locally.
   - If the tool is unknown (e.g. an MCP tool or WASM script), the worker sends a JSON-RPC request (`call_tool_on_gleam`) up the UDS.
   - The supervisor transacts a `"call_tool_request"` Datom to SQLite, which the reactive `intent_loop` handles.
   - Gleam executes the tool via `dispatch_tool` and forwards the result back through the UDS. The worker blocks until the response arrives, then returns it to the LLM.
3. **Context Injection**: Local system configuration snippets collected by `context_engine.gleam` are compiled once during startup and appended directly to the initial prompt sent to the worker.
4. **Datalog Skill Rules**: Relational rules and facts are evaluated inside the Gleam database, and the results are injected into the initial system prompt to guide the worker's LLM turns.

---

## 2. Component-by-Component Conversion Analysis

We analyze whether moving each component from the **Gleam-Level** (Core Orchestrator) to the **Babashka-Level** (Worker Runtime) increases simplicity and utility.

### 2.1. Model Context Protocol (MCP) Client
*   **Gleam-Level (Current)**: Implemented using Erlang Ports. The VM handles process lifecycles and standard I/O streams natively.
*   **Babashka-Level**: Requires managing Java process builders and thread streams in Clojure to pipe JSON-RPC messages.
*   **Rich Hickey Lens**: Erlang Ports are extremely robust and supervised by OTP. Writing a custom subprocess manager in Clojure introduces high runtime complexity (handling zombie processes, thread blocks).
*   **Verdict**: **Keep in Gleam**. The BEAM is structurally superior at supervising OS subprocesses.

### 2.2. WebAssembly (WASM) Sandbox
*   **Gleam-Level (Current)**: Relies on native NIF shims. A memory panic in a third-party C/Rust library can crash the entire BEAM virtual machine.
*   **Babashka-Level**: Can leverage pure-Java/JVM WebAssembly interpreters (like **Chicory**) running directly inside the Babashka GraalVM Native Image container.
*   **Rich Hickey Lens**: Moving WASM execution to Babashka decomplects safety from performance. A WASM panic is caught safely by the worker, preventing VM corruption.
*   **Verdict**: **Convert to Babashka (Recommended for Safety)**. Isolates untrusted tool code execution.

### 2.3. Context Plugins (context_engine.gleam)
*   **Gleam-Level (Current)**: Gathers system state (git, paths, configurations) at initialization.
*   **Babashka-Level**: Gathers system state dynamically during the conversation run using Clojure's expressive Java interop.
*   **Rich Hickey Lens**: Environment checks are side-effects. Keeping them in Gleam keeps the worker pure and task-focused.
*   **Verdict**: **Keep in Gleam**.

### 2.4. Datalog Skill Rules (gleamdb)
*   **Gleam-Level (Current)**: Uses a custom-written functional Datalog engine (`gleamdb.gleam`). It is niche, lacks indices, and requires compiling facts to transacted SQLite datoms.
*   **Babashka-Level**: Clojure is the birthplace of modern in-memory Datalog. Babashka can leverage **DataScript** natively via `bb.edn` dependencies.
*   **Rich Hickey Lens**: DataScript is a highly optimized, mature, and standardized in-memory database. Replacing the custom GleamDB engine with DataScript inside the worker dramatically reduces code volume and complexity while providing high-performance graph/relational matching.
*   **Verdict**: **Convert to Babashka (Highly Recommended)**. Moving rules evaluation to DataScript inside the worker simplifies query logic and boosts execution speed.

---

## 3. Complexity vs. Utility weighted comparison

This table evaluates the trade-offs of converting each component to the Babashka Level.

| Tooling Component | Complexity (Gleam) | Complexity (Babashka) | Utility on Babashka | Weighted Actionability | Strategic Decision |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Datalog Engine** | 8 (Custom) | 2 (DataScript) | 9 | **10.5** | **Convert to Babashka**: Migrate Datalog evaluation to DataScript in the Clojure worker. |
| **WASM Executor** | 6 (NIF risk) | 4 (JVM Sandbox) | 7 | **7.5** | **Convert to Babashka**: Run WASM tools inside GraalVM boundaries for safety. |
| **MCP Client** | 3 (OTP Ports) | 7 (Java streams) | 6 | **3.0** | **Keep in Gleam**: Delegate MCP servers via Erlang port supervisors. |
| **Context Engine** | 4 | 3 | 5 | **4.5** | **Keep in Gleam**: Inject context once during socket initialization. |

---

## 4. Actionable Recommendation

1. **Migrate Datalog Skills to DataScript**:
   Instead of compiling skills to SQLite datoms and querying them via custom `gleamdb` logic, load skill rules into an in-memory DataScript database inside `worker.clj`. The LLM turns can query DataScript directly using native Clojure syntax, simplifying code and accelerating execution.
2. **Move WASM Tool Execution to Worker**:
   Embed a Java-based WASM runtime inside the Babashka worker dependencies to execute sandboxed tools locally, preventing native NIF crashes from affecting the BEAM VM.
3. **Retain MCP and Context in Gleam**:
   Maintain the UDS socket delegation for MCP servers to leverage Erlang's superior subprocess supervision trees.
