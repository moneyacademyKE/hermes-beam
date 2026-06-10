# Gap Analysis: Co-existence (GleamDB + Micro-Datalog) vs. Consolidation

> [!NOTE]
> **Post-Implementation Update (June 2026)**
> Since this gap analysis was performed, the architecture transitioned to **Approach B1 (Consolidation)**. The custom `gleamdb.gleam` engine was completely removed to prevent duplication of roles and reduce maintenance overhead. The orchestrator was stripped down strictly to a persistence and routing layer, representing all state transitions as append-only transaction logs (SQLite datoms). All Datalog query evaluation (such as permission checks and evolutionary logic loops) has been successfully consolidated into the Clojure worker (`worker.clj`) via local subprocess CLI queries, resolving the scheduling/blocking concerns with sub-100ms CLI latency.

This analysis evaluates the architectural trade-offs between two options:
1. **Approach A (Co-existence)**: Retain both **GleamDB** (on the orchestrator/BEAM side for state tracking, permissions, and reactive side-effects) and the **Micro-Datalog** engine (on the worker/Babashka side for sandboxed JVM-free execution).
2. **Approach B (Consolidation)**: Consolidate onto a single engine. This would involve either:
   - Deprecating GleamDB and delegating all orchestrator queries to the Clojure worker via UDS.
   - Or improving GleamDB (e.g. adding backward-chaining/unification) and porting the worker's logic back to Gleam.

---

## 1. Structural Comparison

### Approach A: Co-existence (Dual Engine Model)
In this model, the two engines operate in distinct processes separated by a clean Unix Domain Socket (UDS) boundary:
*   **GleamDB** lives in the orchestrator. It acts as an in-memory materialized view of transaction logs, driving the reactive Erlang `intent_loop` (broadcasting tool execution events like `spawn_worker`).
*   **Micro-Datalog** lives in the worker. It serves as a query sandbox for the LLM to run Datalog query tools (`query_datalog`, `transact_datalog`) dynamically.

```
+-------------------------------------------------------------+
|                     Gleam Orchestrator                      |
|  - SQLite (EAV Datoms Table)                                |
|  - GleamDB (Materialized views, intent_loop, permissions)   |
+-------------------------------------------------------------+
                               |
                        UDS (JSON-RPC)
                               |
+-------------------------------------------------------------+
|                      Babashka Worker                        |
|  - Micro-Datalog Engine (On-the-fly backward chaining)       |
|  - Tool Sandbox & execution environment                     |
+-------------------------------------------------------------+
```

### Approach B: Consolidation (Single Engine Model)
*   **Sub-Option B1 (Worker Only)**: Deprecate GleamDB entirely. Any time the orchestrator needs to check permissions or route an intent, it must issue a synchronous JSON-RPC request to the Babashka worker process.
*   **Sub-Option B2 (Orchestrator Only)**: Deprecate Micro-Datalog. The worker delegates all `query_datalog` and `transact_datalog` requests back to the Gleam orchestrator via JSON-RPC.

---

## 2. Feature & Architectural Trade-offs

| Dimension | Co-existence (Dual Engine) | Consolidation: Worker Only (B1) | Consolidation: Orchestrator Only (B2) |
| :--- | :--- | :--- | :--- |
| **VM Concurrency & Safety** | **High**<br>State transitions remain fast and local in Erlang. Sandbox operations are isolated in Clojure. | **Low**<br>BEAM must block or handle async await states for simple permission checks by querying Clojure. | **Moderate**<br>BEAM handles all queries; Clojure worker acts strictly as a shell sandbox. |
| **System Complexity** | **Low-to-Moderate**<br>Two small codebases (~130 lines of Gleam, ~80 lines of Clojure), each optimized for its execution runtime. | **High**<br>Conflates orchestrator queries with subprocess lifecycle. If the worker crashes, the orchestrator loses routing logic. | **High**<br>Every LLM turn doing query/transact must block on UDS roundtrips to the orchestrator, increasing latency. |
| **Boot and Memory Overhead** | **Low**<br>Erlang starts instantly; Babashka boots in under 50ms due to GraalVM/JVM-free design. | **Low**<br>Slightly lower memory as GleamDB datastructures are removed. | **Low**<br>Slightly lower memory inside the worker. |
| **Feature Richness** | **Optimal**<br>Orchestrator uses forward-chaining (fast static checks); worker uses backward-chaining (fast dynamic rules). | **Sub-optimal**<br>Orchestrator queries suffer from JSON serialization/deserialization over socket boundaries. | **Sub-optimal**<br>GleamDB lacks complex unification (e.g. recursive logic variable resolution). |

---

## 3. Complexity vs. Utility Analysis

```
  High |                                [Co-existence]
       |                                (Optimal runtimes, decoupled, zero-blocking)
U      |
T      |                [Consolidation B2]
I      |                (Orchestrator-heavy, UDS latency)
L      |
I      |                [Consolidation B1]
T      |                (Worker-heavy, blocks BEAM scheduler)
Y      |
  Low  +------------------------------------------------
       Low                                         High
                          COMPLEXITY
```

*   **Co-existence (Dual Engine)**:
    *   *Complexity*: Low. Both engines are extremely small (<200 lines combined) and have zero external dependencies.
    *   *Utility*: High. It aligns with the **Decomplecting Runtimes** design pattern: Gleam/BEAM excels at high-concurrency event loops and supervisor structures, while Clojure/Babashka excels at fast interactive scripting and query evaluation.
*   **Consolidation B1 (Worker Only)**:
    *   *Complexity*: High. Introduces circular dependency patterns (Orchestrator needs worker to check if it should spawn a worker).
    *   *Utility*: Low. Slows down basic state reads.
*   **Consolidation B2 (Orchestrator Only)**:
    *   *Complexity*: High. Requires upgrading `gleamdb` to support advanced backward-chaining and nested logical variable unification, complicating the statically-typed Gleam codebase.
    *   *Utility*: Moderate. Solves query execution but forces UDS roundtrips for every worker logic turn.

---

## 4. Actionable Recommendation

**Proceed with Approach A (Co-existence of both GleamDB and Micro-Datalog).**

### Rationale:
1. **Decomplecting Failure Domains**:
   As per Rich Hickey's principles, complecting the orchestrator's state-routing logic with the worker's execution environment is dangerous. Keeping GleamDB on the orchestrator side ensures that even if a sandboxed command completely locks up or breaks the worker, the supervisor tree (`subagent_supervisor.gleam`) can tear down the socket, spawn a new worker, and restore state from SQLite datoms without losing active routing tables.
2. **Execution Matching**:
   *   `gleamdb`'s forward-chaining is ideal for *static system states* (e.g., checking permissions, finding active session models) because these are write-once, read-many checks.
   *   `micro-datalog`'s backward-chaining is ideal for *dynamic LLM tool reasoning* (e.g., resolving transitive dependencies on-the-fly during code execution loops), where writing rules is fast and fact pools are transient.
3. **Low Maintenance Cost**:
   Because both implementations are written from scratch without any library dependencies (JVM-free for Clojure, native stdlib for Gleam), they do not introduce package auditing concerns or supply-chain vectors.
