# Gap Analysis: Clojure Micro-Datalog vs. GleamDB

> [!NOTE]
> **Post-Implementation Update (June 2026)**
> Since this gap analysis was performed, the custom in-memory Datalog engine `gleamdb.gleam` was deprecated and completely removed from the repository. The Clojure micro-Datalog interpreter inside the Babashka worker (`worker.clj`) is now the sole logical Datalog engine in the system. The orchestrator delegates logic evaluation (such as permissions checks and evolutionary skill optimization queries) to the Clojure worker over CLI stdin/stdout boundaries, achieving a clean separation of roles and preventing engine duplication.

This document performs a thorough and comprehensive Rich Hickey Gap Analysis comparing the new pure-Clojure **micro-Datalog** engine (implemented inside [worker.clj](file:///Users/moe/Desktop/ayncoder/babashka_workers/src/worker.clj)) against the previous Gleam-based **GleamDB** engine ([gleamdb.gleam](file:///Users/moe/Desktop/ayncoder/hermes_beam/src/gleamdb.gleam)).

---

## 1. Feature Set Difference Matrix

| Feature / Dimension | Previous GleamDB (`gleamdb.gleam`) | New Clojure Micro-Datalog (`worker.clj`) | Benefit / Trade-off |
| :--- | :--- | :--- | :--- |
| **Execution Context** | In-process native Erlang BEAM actor | Out-of-process Babashka scripting process | **GleamDB**: Zero-latency native FFI boundaries.<br>**Micro-Datalog**: Strong isolation; execution crashes don't affect BEAM scheduler. |
| **Evaluation Strategy** | **Forward Chaining (Materialization)**<br>Iterative fixpoint calculation (`evaluate_rules`) that pre-computes and transacts all derived facts into the DB before querying. | **Backward Chaining (On-the-fly resolution)**<br>Recursively solves rule bodies (`solve-rule`) dynamically during query execution. | **GleamDB**: Fast queries once materialized; slow startup/update time.<br>**Micro-Datalog**: Zero pre-computation delay; slightly slower query times for deep rules. |
| **Logic Variable Representation** | String prefixed with "?" (`"?x"`) | Clojure symbols starting with "?" (`?x`) | **Micro-Datalog**: Uses native Clojure reader representation; simplifies parsing and pattern matching. |
| **Indexing** | Attribute-level index `Dict(String, List(Datom))` to filter scan pools | Linear scan (unindexed `keep` filter) | **GleamDB**: Scale-friendly for large datom counts.<br>**Micro-Datalog**: Lower code complexity (~10 lines vs indexing loops). High throughput for small fact pools. |
| **Unification** | Simple string equality and env binding | Recursive resolution (`resolve-term`) supporting nested logical bindings | **Micro-Datalog**: More robust pattern resolution. Variable bindings resolved recursively. |
| **Entity ID Integration** | Flat String IDs only | Integer IDs with `:name` mappings (mimicking DataScript structure) | **Micro-Datalog**: Compatible with existing DataScript schemas, allowing drop-in migrations for skill evaluation. |
| **Mutating Transactions** | Purely functional (`transact` returns new `Database`) | Local state wrapper via Clojure `atom` | **GleamDB**: Mathematically pure; easy time-travel.<br>**Micro-Datalog**: Simple to update on-the-fly in stateful worker. |

---

## 2. Deep Dive Analysis

| Component | Essential Complexity | Accidental Complexity | Utility | Hickey Assessment |
| :--- | :--- | :--- | :--- | :--- |
| **Forward Chaining vs. Backward Chaining** | | | | |
| *   **GleamDB (Forward Chaining)**: When rules are supplied, GleamDB runs a fixpoint loop: `evaluate_rules`. It evaluates every rule body against current facts, generates new derived facts, transacts them back into the database, and repeats until the fact count stabilizes. *Trade-off*: Excellent for read-heavy systems where rules rarely change, but suffers from $O(N)$ execution overhead every time the database receives new facts. | | | | |
| *   **Micro-Datalog (Backward Chaining)**: Rather than pre-computing derived facts, the Clojure engine traverses clauses lazily. When `solve-clause` encounters a clause structure that matches a rule head, it dynamically rewrites variables (`rename-vars` with suffix tracking to prevent collisions) and resolves the body clauses recursively. *Trade-off*: Eliminates the initialization/transact tax entirely. Extremely lightweight and simple, but query execution latency scales with rule depth. | | | | |

### 2.2. Variable Binding and Unification
*   **GleamDB**: Bound values are strings. Variable scoping is flat. Since Gleam lacks macro expansion, query syntax is constructed using tuple structures (`#("?entity", "user/email", "?email")`).
*   **Micro-Datalog**: Since Clojure is homoiconic, queries are written as native Clojure data structures (EDN). The engine uses `resolve-term` to follow variable references recursively:
    ```clojure
    (defn resolve-term [term env]
      (loop [t term seen #{}]
        (if (and (symbol? t) (clojure.string/starts-with? (name t) "?"))
          (if (seen t) t
              (if-let [bound (get env t)]
                (recur bound (conj seen t))
                t))
          t)))
    ```
    This enables full variable unification across multi-step joins without intermediate casting.

### 2.3. Complexity vs. Utility Analysis

```
  High |                                [Micro-Datalog]
       |                                (Flexible, isolated, zero-dep, JVM-free)
U      |
T      |
I      |                [GleamDB]
L      |                (BEAM-integrated,
I      |                 indexed, rigid)
T      |
Y      |
  Low  +------------------------------------------------
       Low                                         High
                          COMPLEXITY
```

*   **GleamDB**:
    *   *Complexity*: Moderate. The custom fixpoint logic and index construction must be maintained in Gleam.
    *   *Utility*: Low-to-Moderate. Harder to write complex recursive rules, and lacks a native REPL or EDN integration.
*   **Clojure Micro-Datalog**:
    *   *Complexity*: Low. Decomplects evaluation by removing external databases (DataScript/JVM), implementing core unification in under 80 lines of pure Clojure.
    *   *Utility*: High. Evaluates rules on the fly, integrates seamlessly with Babashka scripting, and utilizes Clojure's native symbol manipulation.

---

## 3. Actionable Recommendation

**Retain the Clojure Micro-Datalog Engine in the Subagent Worker.**

### Why?
1. **JVM-Free Compliance**: By implementing a pure-Clojure evaluator inside the worker, we bypass the need for DataScript (which depends on JVM bytecode wrappers), allowing Babashka to run natively in sub-millisecond boot environments.
2. **Decomplected Architecture**: GleamDB is excellent for simple, global orchestrator-side intent routing. However, for evaluating LLM-driven tool execution and complex recursive logic skills inside isolated subagents, executing Datalog *within* the Babashka worker process ensures sandbox boundaries are never breached, separating orchestrator state from worker side-effects.
3. **No Migration Overhead**: The micro-Datalog parser replicates the same relational query inputs (`[:find ?y :where ...]`) as DataScript, meaning no prompt rewrites or skill schema adjustments were required to make the switch.
