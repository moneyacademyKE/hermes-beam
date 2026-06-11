# Babashka Worker Learnings

This document summarizes the core learnings from developing socket diagnostic scripts, logs analysis practices, and the custom Datalog and Graph analytics engine in Babashka.

## 1. Socket Communications & Log Analysis
- Scanning log files for socket connection failures dynamically yields reports like `diagnostic_report.md`.
- Simple log analysis scripts can identify network routing failures, port blockages, and socket connection timeouts.

## 2. Babashka SCI Sandbox Constraints
- Standard Java classes like `java.util.BitSet` are blocked in sandboxed SCI environments (e.g. Babashka executors).
- Representing bit vectors and filters using Clojure persistent sets (`#{}`) maintains 100% compatibility and portability without JVM class loading.

## 3. Query Planner Selectivity & Cost Optimization
- Executing Datalog clauses in declaration order risks performance degradation.
- A cost-based greedy clause planner (`reorder-clauses`) ensures that highly selective (highly bound) clauses run first.
- Deferring filters and negative clauses (`not`) until all their variables are bound prevents unbound variable errors.

## 4. Analytical Aggregates & Grouping
- Aggregation functions (`count`, `sum`, `min`, `max`, `avg`, `median`) can be computed over query result environments by grouping by the non-aggregated variables.
- Double-precision formatting is necessary for `avg` and `median` computations.

## 5. Pure Clojure Graph Algorithms
- Sophisticated graph algorithms (PageRank, Tarjan's SCC, Kahn's Topological Sort, BFS Shortest Path, DFS Cycle Detection) can be implemented in pure Clojure using core collections, avoiding heavy external library dependencies or custom BEAM NIFs.
- DFS stack extraction using Clojure's `.indexOf` and `subvec` ensures that cycle paths are extracted in order and free of prefixes.
