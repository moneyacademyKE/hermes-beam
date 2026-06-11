# Babashka Worker Design Patterns

This document outlines structural and design patterns utilized in Babashka worker scripts.

## 1. Functional Log Diagnostics
- Parse line-delimited log files using pure Clojure functions (`clojure.string/split`, `filter`, `reduce`).
- Log diagnostic and error output to `*err*` instead of standard stdout to preserve IPC channel integrity.

## 2. Index-Driven Pattern Matching
- Perform a single O(N) pass to build `EAV`, `AVE`, and `AEV` maps from raw datom triples.
- Select the lookup index dynamically at query time based on grounding states.

## 3. Cost-Based Clause Reordering
- Score datalog clauses based on current variable grounding: low score for bound triples, high score for unbound triples and filters.
- Reorder clauses greedily before execution to prevent combinatorial explosion.

## 4. Grouped Aggregation Projections
- Group resolved binding environments by the values of the non-aggregated variables.
- Apply reducer functions (e.g. `count`, `sum`, `min`, `max`, `avg`, `median`) to target variables within each group.

## 5. Multi-Graph Predicates
- Construct graph adjacency representations on-the-fly using the database's `AEV` index.
- Expose graph traversals (Shortest Path, Reachable nodes, Cycle Detection, Kahn's Topological Sort, PageRank, Tarjan's SCC) as composable query clauses.

## 6. SCI-Compliant Bloom Filters
- Model the bit set using a Clojure persistent set of active bit indices.
- Map keys to bits via salted hashes modulo the filter size.
- Perform membership checks by verifying if the key's hash index set is a subset of the active set.
