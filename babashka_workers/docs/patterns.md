# Clojure/Babashka Datalog & Graph Engine Design Patterns

This document details the architectural and structural design patterns implemented in the `worker.clj` Clojure Datalog and Graph analytics suite.

---

## 1. Index-Driven Datalog Pattern Matching

### Intent
Replace linear $O(N)$ searches over a database facts list with $O(1)$ or $O(k)$ lookups using multiple hash-map indexes.

### Pattern
*   **Single-Pass Indexing**: On initialization or transaction, construct three complementary maps in a single reduction pass:
    - `EAV` (Entity-Attribute-Value) for quick value lookups on a known entity.
    - `AVE` (Attribute-Value-Entity) for reverse indexing.
    - `AEV` (Attribute-Entity-Value) for entity list extraction on a known attribute.
*   **Grounded Variable Selection**: Inspect the grounded state of query pattern elements to determine the optimal index key path, falling back to full scans only when no variables are grounded.

### Example (Clojure)
```clojure
(defn index-lookup [db pe pa pv env]
  (let [re (resolve-term pe env)
        ra (resolve-term pa env)
        rv (resolve-term pv env)
        e-bound? (not (variable? re))
        a-bound? (not (variable? ra))]
    (cond
      (and e-bound? a-bound?) (get-in (:eav db) [re ra])  ; O(1)
      (and a-bound? (not (variable? rv))) (get-in (:ave db) [ra rv]) ; O(1)
      :else (:facts db)))) ; fallback
```

---

## 2. Cost-Based Join Reordering

### Intent
Automatically reorder a sequence of Datalog clauses at runtime to minimize the size of intermediate result sets.

### Pattern
*   **Static Grounding Analysis**: Analyze which variables are known (grounded) at the start of query execution.
*   **Greedy Cost Minimization**: Select the clause that has the lowest cost relative to the current grounded variable set. Positive triples with bound elements have low cost, while filters and unbound triples have high cost.
*   **Bound-Set Propagation**: After choosing a clause, add all of its variables to the grounded variable set and repeat the selection process for the remaining clauses.

---

## 3. Negation-as-Failure (NAF) Constraint

### Intent
Prune binding environments that satisfy a specific negative condition without introducing new variables.

### Pattern
*   **Grounding Pre-requisite**: Ensure that all variables in the negative clause are grounded before execution.
*   **Solve-and-Filter**: Run the inner clause against the database using the current binding environment. If a non-empty set of binding environments is returned, the current environment fails the negation constraint and is discarded.

---

## 4. Grouped Aggregation Projections

### Intent
Support SQL-like grouping and reduction over unified variables in Datomic-style query syntax.

### Pattern
*   **Signature Extraction**: Identify which clauses in the `:find` query vector contain aggregate functions: `(count ?e)`, `(sum ?x)`, etc.
*   **Binding Partitioning**: Group the set of resolved binding environments by the values of the non-aggregated variables.
*   **Reduce Group Values**: Apply the target reducer (`count`, `sum`, `min`, `max`, `avg`, `median`) over the list of resolved values for each partition.

---

## 5. Multi-Graph Composable Predicates

### Intent
Integrate complex graph algorithms (Shortest Path, Reachable nodes, Cycle Detection, Kahn's Topological Sort, PageRank, Tarjan's SCC) natively into the query processing pipeline.

### Pattern
*   **Graph Construction**: Rebuild the graph adjacency map dynamically using the attribute-indexed `AEV` map to represent directed links.
*   **Unified Solver Interface**: Conform each graph algorithm to the standard datalog resolver interface: taking the database, binding environment, and returning a sequence of updated binding environments.

---

## 6. SCI-Compliant Bloom Filter

### Intent
Implement a space-efficient set membership checker that runs successfully inside Babashka's restricted SCI sandbox without classpath or sandbox-exec errors.

### Pattern
*   **Persistent Set Representation**: Instead of using `java.util.BitSet` (which is typically blocked in SCI sandboxes), model the active bit array using a standard Clojure persistent set (`#{}`).
*   **Salting Hashes**: Generate multiple hash indices for a given key by salting the key with a range sequence and taking the absolute value modulo the filter size.
*   **Subset Match**: Check if the set of computed hash indices is a subset of the active bit set.

---

## 7. Boundary Type Coercion for Heterogeneous JSON-to-EDN Transpilation

### Intent
Map statically-typed query representations (Gleam AST variants) cleanly onto dynamic symbolic execution environments (Clojure) across standard JSON payload streams.

### Pattern
*   **Structured JSON Serialization**: Serialize query ASTs to JSON arrays (e.g. `["not", ["?e", "blocked", "true"]]` or `[[">", "?a", 25]]`).
*   **Dynamic Postwalk Coercion**: Walk the JSON-parsed structure in Clojure and dynamically replace any string matching operator names or starting with `?` with their respective Clojure symbol representation.