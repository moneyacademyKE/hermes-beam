# Clojure/Babashka Datalog & Graph Engine Learnings

This document contains key technical learnings from implementing Aarondb's advanced Datalog capabilities and graph algorithms suite within a 100% JVM-free, Babashka-compatible execution runtime.

---

## 1. Babashka SCI Sandbox Constraints

*   **Problem**: In standard Clojure development, binary structures like Bloom filters are backed by `java.util.BitSet` for maximum performance and bit-packing efficiency. However, the Small Clojure Interpreter (`sci`) environment under which Babashka executes scripts enforces strict sandbox limits. Classpath access to `java.util.BitSet` is disabled by default, throwing class resolution errors.
*   **Resolution**: We refactored the Bloom filter to store active bit indices in a standard Clojure persistent set (`#{}`). Hash index generation uses a pure Clojure hashing function:
    ```clojure
    (defn- bloom-hashes [key size hash-count]
      (map (fn [i]
             (let [h (hash [key i])]
               (mod (Math/abs h) size)))
           (range 1 (inc hash-count))))
    ```
*   **Learning**: When writing libraries for sandboxed environments like SCI, avoid all non-primitive Java classes. Model data structures using pure Clojure map/set collections, which guarantees out-of-the-box compatibility without configuration overrides.

---

## 2. Floating-Point Comparison in Centrality and Vector Algorithms

*   **Problem**: Algorithms that calculate vector similarity (Cosine Similarity) or node centrality weights (PageRank) operate on double-precision floating-point numbers. Due to IEEE 754 precision representation limits, operations can yield slight rounding errors (e.g. PageRank values sum to `0.9999999999999998` instead of exactly `1.0`). Exact checks with `=` or `==` fail under these conditions.
*   **Resolution**: Implement delta-based threshold assertions in verification code:
    ```clojure
    (defn- rank-close-to? [expected actual]
      (< (Math/abs (- (double expected) (double actual))) 1e-9))
    ```
*   **Learning**: Floating-point values produced by iterative graph math must always be compared using a tolerance delta ($10^{-9}$ or similar) in both assertions and query filters to prevent brittle test cases.

---

## 3. Sub-vector Extraction in DFS Cycle Detection

*   **Problem**: Standard DFS-based cycle detection identifies cycles when a node points back to a vertex currently in the recursion stack (back-edge). Once detected, the exact cyclic path must be extracted. Simply dumping the current traversal path results in incorrect prefixes (it includes nodes visited before the cycle loop started).
*   **Resolution**: Track the active recursion stack as a sequential vector. When a back-edge pointing to `neighbor` is detected, query its index in the stack vector using `.indexOf` and extract the sub-vector starting from that index:
    ```clojure
    (let [idx (.indexOf stack neighbor)
          cycle (if (neg? idx) [neighbor] (subvec stack idx))]
      (swap! cycles-ref conj cycle))
    ```
*   **Learning**: Clojure vectors support fast indexing and slices (`subvec`) that preserve order. This is highly suitable for path extraction in DFS search algorithms.

---

## 4. Cost-Based Query Planning Selectivity Penalities

*   **Problem**: The greedy optimizer is designed to order positive triples so they execute in descending order of grounding. However, filters and negative clauses (`not`) must only execute once their variables have been bound by positive matches. Running them too early results in "Unbound variable in filter" errors or invalid negation scoping.
*   **Resolution**: Assign a prohibitive selectivity cost to unbound filters (`8000`) and negative clauses (`5000`) if their variables are not yet subset of the currently bound variables.
*   **Learning**: De-complecting query planning from query execution means the planner must have a static cost model that perfectly reflects runtime capabilities. Penalizing unbound predicates forces they execute at the end of the query pipeline, acting as true filters over grounded environments.

---

## 5. Self-Invalidating Atom-Based LRU Caching

*   **Problem**: Query resolution (especially graph algorithms) is CPU-expensive. Caching query results is necessary, but standard cache invalidation is complex and error-prone.
*   **Resolution**: The query cache is an atom-backed map. The cache key includes the entire `:facts` database vector. Because the database is treated as an immutable value, any `transact_datalog` operation updates the database's facts vector, modifying the cache key automatically.
*   **Learning**: By modeling the database as a value and including this value inside the query cache key, cache invalidation becomes a zero-cost byproduct of functional immutability.

---

## 6. JSON Serialization Boundary Coercion

*   **Problem**: When passing structured queries from a typed environment (Gleam) to an untyped worker (Clojure) via JSON, symbol types are serialized as strings. This breaks standard unification and comparison checks in the Datalog engine, as `"not"` does not equal `'not`.
*   **Resolution**: Run a postwalk symbol coercion pass over parsed JSON arrays inside `parse-clause-helper`, converting known operators and variables starting with `?` back into Clojure symbols at the scripting boundary.
*   **Learning**: Dynamic scripting engines receiving JSON queries must establish a clean boundary layer to coerce inputs into internally-expected algebraic/symbolic representations.