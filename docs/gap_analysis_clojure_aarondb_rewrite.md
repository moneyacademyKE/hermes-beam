# Gap Analysis: Custom Micro-Datalog vs. Clojure Rewrite of Aarondb

This document performs a thorough Rich Hickey Gap Analysis comparing our **Current Custom Micro-Datalog interpreter** (~80 lines in `worker.clj`) against a proposed **Native Clojure Rewrite of Aarondb's Subset** inside the Babashka worker.

---

## 1. Feature Set Difference Matrix

| Feature / Dimension | Current Micro-Datalog (`worker.clj`) | Clojure Aarondb Rewrite | Benefit / Trade-off |
| :--- | :--- | :--- | :--- |
| **Code Size & Footprint** | Extremely small (~80 lines of pure Clojure). | Estimated 1,500–2,500 lines of Clojure. | **Micro-Datalog**: Trivial to maintain, boots instantly. **Aarondb Rewrite**: High maintenance tax and boot overhead. |
| **Query Strategy** | **Top-down Backward Chaining**<br>Lazy recursive unification at query time. | **Bottom-up Semi-Naive / Index-Driven**<br>Pre-calculates relations using index tables. | **Micro-Datalog**: Zero transaction latency; slow query times on deep rules.<br>**Aarondb Rewrite**: Microsecond queries; transaction overhead for index rebuilds. |
| **Indexing Structure** | None (linear scan over facts atom). | Triple indexes: EAVT, AEVT, AVET, VAET using nested Clojure maps. | **Micro-Datalog**: Simple. **Aarondb Rewrite**: Scalable for millions of facts, but redundant for small session fact pools. |
| **Pull API** | Not supported (requires manual queries to resolve entities). | Full Datomic-style Pull API supporting nested patterns (wildcards, recursion). | **Aarondb Rewrite**: Drastically simplifies pulling complex entity graphs. |
| **Graph Operations** | General Prolog-style recursion. | Native graph algorithms (Shortest Path, Centrality, PageRank). | **Aarondb Rewrite**: Optimized graph reasoning (e.g. for cluster maps). |
| **Negation & Aggregates** | Not supported. | Native `not`, `not-join`, and aggregates (`sum`, `count`, `avg`, `min`, `max`). | **Aarondb Rewrite**: Standard Datalog completeness. |

---

## 2. Deep Dive: Architectural Implications

### 2.1. Unification vs. Indexing (Rich Hickey Lens)
*   **Current Micro-Datalog**: Treats the database as a simple flat sequence of facts. Queries filter the list and recursively bind variables.
    *   *Decomplected*: Zero state management other than a single atom.
    *   *Trade-off*: A query over 10,000 facts with multiple joins will perform poorly because it lacks indexes.
*   **Clojure Aarondb Rewrite**: Requires building and updating structured indexes:
    ```clojure
    (defn add-to-index [idx e a v t]
      (update-in idx [e a v] conj t))
    ```
    *   *Complected*: Time and value are braided together to manage the lifecycle of indexes during transactions.
    *   *Benefit*: Query resolution becomes $O(1)$ lookups instead of $O(N)$ linear scans.

### 2.2. The Pull API Gap
`aarondb` features a standard Pull API (`PullPattern = List(PullItem)`).
*   In the **Current Micro-Datalog**, to reconstruct a session's messages, the orchestrator must execute multiple queries and join the results in Gleam.
*   In a **Clojure Aarondb Rewrite**, the orchestrator could issue a single pull query:
    ```clojure
    (pull db '[* {:session/messages [:message/content :message/role]}] session-id)
    ```
    This completely deconstructs entity graphs into structured JSON natively inside the worker.

---

## 3. Complexity vs. Utility Analysis

```
  High |                                [Clojure Aarondb Rewrite]
       |                                (Pull API, Triple Indexes, Aggregates)
U      |
T      |
I      |                [Current Micro-Datalog]
L      |                (Simple, 80 lines,
I      |                 positive clauses only)
T      |
Y      |
  Low  +------------------------------------------------
       Low                                         High
                           COMPLEXITY
```

### 3.1. Current Micro-Datalog
*   **Complexity**: Extremely Low. Fits entirely in a single screen.
*   **Utility**: High (for permissions and basic path queries).
*   **Hickey Assessment**: **Excellent**. Decomplecting the engine to its absolute bare minimum logic ensures it is robust and bug-free.

### 3.2. Clojure Aarondb Rewrite
*   **Complexity**: High. Managing multiple indexes, query planning, semi-naive evaluation loops, and pull parsers in pure Clojure is a substantial engineering task.
*   **Utility**: Very High (fully replaces SQLite and provides a complete relational engine in the worker).
*   **Hickey Assessment**: **Incidental Bloat**. Rewriting a complete database engine inside a script runner replicates work that is already handled by SQLite at the persistence layer.

---

## 4. Weighted Trade-off Analysis

| Dimension | Current Micro-Datalog | Clojure Aarondb Rewrite | Trade-off Verdict |
| :--- | :--- | :--- | :--- |
| **Boot Speed** | Instantly (< 1ms classloading) | Minor classloading overhead (~10-20ms) | **Micro-Datalog** is faster due to zero dependency loads. |
| **Correctness** | Trivial to verify | High risk of edge cases in index updates/unification | **Micro-Datalog** wins on ease of testing. |
| **Feature Richness**| Limited to 3-element positive clauses | Pull API, Negation, Aggregates | **Aarondb Rewrite** is significantly more powerful. |

---

## 5. Actionable Recommendation

**Maintain the Current Micro-Datalog Engine for session reasoning, and do not rewrite Aarondb in Clojure.**

### Why?
1. **Accidental Database Creation**: SQLite already acts as our high-performance, indexed, transactional storage engine. Rewriting `aarondb`'s indexing and query planning in Clojure is rebuilding a database engine on top of a database engine.
2. **Context Size Limits**: The fact pools evaluated during an agent turn are tiny (typically < 100 facts for permissions, and < 50 facts for active skills). At this scale, linear scans are extremely fast (< 1ms), making index optimization overhead completely redundant.
3. **Keep the Edge Simple**: By keeping the worker stateless and simple, we ensure it remains a reliable execution sandboxed runner.
