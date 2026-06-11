#!/usr/bin/env bb
;; ─── Indexed Datalog Engine Tests ────────────────────────────────────────────
;;
;; Run:  bb babashka_workers/test_worker_datalog.clj
;;
;; Tests the aarondb-ported indexed Datalog engine in worker.clj:
;;   1. Index construction (EAV/AVE/AEV)
;;   2. Term unification and variable resolution
;;   3. Index-driven pattern matching
;;   4. Rule evaluation (recursive, cycle-guarded)
;;   5. End-to-end query-datalog pipeline
;; ──────────────────────────────────────────────────────────────────────────────

(require '[clojure.string :as str])

;; ── Load worker.clj engine functions ─────────────────────────────────────────
;; We load the worker namespace but don't run -main
(load-file "babashka_workers/src/worker.clj")

(def pass-count (atom 0))
(def fail-count (atom 0))
(def test-names (atom []))

(defn assert-eq [test-name expected actual]
  (if (= expected actual)
    (do (swap! pass-count inc)
        (swap! test-names conj [:pass test-name]))
    (do (swap! fail-count inc)
        (swap! test-names conj [:fail test-name])
        (binding [*out* *err*]
          (println (str "FAIL: " test-name))
          (println (str "  expected: " (pr-str expected)))
          (println (str "  actual:   " (pr-str actual)))))))

(defn assert-true [test-name actual]
  (assert-eq test-name true (boolean actual)))

(defn assert-false [test-name actual]
  (assert-eq test-name false (boolean actual)))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 1: variable? predicate
;; ═══════════════════════════════════════════════════════════════════════════════

(assert-true "variable? recognizes ?x" (worker/variable? '?x))
(assert-true "variable? recognizes ?foo" (worker/variable? '?foo))
(assert-false "variable? rejects :keyword" (worker/variable? :name))
(assert-false "variable? rejects string" (worker/variable? "hello"))
(assert-false "variable? rejects number" (worker/variable? 42))
(assert-false "variable? rejects plain symbol" (worker/variable? 'foo))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 2: build-indexes
;; ═══════════════════════════════════════════════════════════════════════════════

(let [facts [["alice" :name "Alice"]
             ["alice" :age 30]
             ["bob"   :name "Bob"]
             ["bob"   :friend "alice"]]
      idx (worker/build-indexes facts)]

  ;; EAV structure
  (assert-true "EAV: alice has :name"
               (contains? (get-in (:eav idx) ["alice" :name]) "Alice"))
  (assert-true "EAV: alice has :age"
               (contains? (get-in (:eav idx) ["alice" :age]) 30))
  (assert-true "EAV: bob has :friend"
               (contains? (get-in (:eav idx) ["bob" :friend]) "alice"))

  ;; AVE structure
  (assert-true "AVE: :name 'Alice' -> alice"
               (contains? (get-in (:ave idx) [:name "Alice"]) "alice"))
  (assert-true "AVE: :name 'Bob' -> bob"
               (contains? (get-in (:ave idx) [:name "Bob"]) "bob"))
  (assert-true "AVE: :friend 'alice' -> bob"
               (contains? (get-in (:ave idx) [:friend "alice"]) "bob"))

  ;; AEV structure
  (assert-true "AEV: :name has alice"
               (contains? (get-in (:aev idx) [:name "alice"]) "Alice"))
  (assert-true "AEV: :age has alice"
               (contains? (get-in (:aev idx) [:age "alice"]) 30))

  ;; facts passthrough
  (assert-eq "facts preserved in index" facts (:facts idx)))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 3: resolve-term
;; ═══════════════════════════════════════════════════════════════════════════════

(assert-eq "resolve-term: unbound var returns itself"
           '?x (worker/resolve-term '?x {}))

(assert-eq "resolve-term: bound var returns value"
           42 (worker/resolve-term '?x {'?x 42}))

(assert-eq "resolve-term: transitive binding"
           "hello" (worker/resolve-term '?x {'?x '?y '?y "hello"}))

(assert-eq "resolve-term: non-variable passes through"
           :name (worker/resolve-term :name {'?x 42}))

(assert-eq "resolve-term: cycle terminates"
           '?x (worker/resolve-term '?x {'?x '?y '?y '?x}))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 4: unify
;; ═══════════════════════════════════════════════════════════════════════════════

(assert-eq "unify: var with constant"
           {'?x 42} (worker/unify '?x 42 {}))

(assert-eq "unify: constant with var"
           {'?x 42} (worker/unify 42 '?x {}))

(assert-eq "unify: equal constants"
           {} (worker/unify 42 42 {}))

(assert-eq "unify: unequal constants fail"
           nil (worker/unify 42 99 {}))

(assert-eq "unify: two vars"
           {'?x '?y} (worker/unify '?x '?y {}))

(assert-eq "unify: bound var matches value"
           {'?x 42} (worker/unify '?x 42 {'?x 42}))

(assert-eq "unify: bound var conflicts"
           nil (worker/unify '?x 99 {'?x 42}))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 5: index-lookup — O(1) path (EAV with bound entity + attribute)
;; ═══════════════════════════════════════════════════════════════════════════════

(let [facts [["alice" :name "Alice"]
             ["alice" :age 30]
             ["bob"   :name "Bob"]]
      db (worker/build-indexes facts)]

  ;; Case 1: e + a bound, v is variable → EAV[e][a]
  (let [envs (worker/index-lookup db "alice" :name '?v {})]
    (assert-eq "index-lookup EAV e+a: binds ?v"
               [{'?v "Alice"}] (vec envs)))

  ;; Case 1b: e + a + v all bound → membership check
  (let [envs (worker/index-lookup db "alice" :name "Alice" {})]
    (assert-eq "index-lookup EAV e+a+v: exact match"
               [{}] (vec envs)))

  (let [envs (worker/index-lookup db "alice" :name "Wrong" {})]
    (assert-eq "index-lookup EAV e+a+v: no match"
               [] (vec envs)))

  ;; Case 2: a + v bound → AVE[a][v]
  (let [envs (worker/index-lookup db '?e :name "Bob" {})]
    (assert-eq "index-lookup AVE a+v: binds ?e"
               [{'?e "bob"}] (vec envs)))

  ;; Case 3: a bound only → AEV[a]
  (let [envs (worker/index-lookup db '?e :name '?v {})]
    (assert-eq "index-lookup AEV a-only: returns all name entries"
               2 (count envs)))

  ;; Case 4: e bound only → EAV[e]
  (let [envs (worker/index-lookup db "alice" '?a '?v {})]
    (assert-eq "index-lookup EAV e-only: returns all alice attrs"
               2 (count envs)))

  ;; Case 5: nothing bound → full scan
  (let [envs (worker/index-lookup db '?e '?a '?v {})]
    (assert-eq "index-lookup full scan: returns all facts"
               3 (count envs))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 6: match-fact via indexed db
;; ═══════════════════════════════════════════════════════════════════════════════

(let [facts [["A" :route/link "B"]
             ["B" :route/link "C"]
             ["A" :name "A"]]
      db (worker/build-indexes facts)]

  (let [envs (worker/match-fact ['?e :route/link '?v] db {})]
    (assert-eq "match-fact: finds both route links"
               2 (count envs)))

  (let [envs (worker/match-fact ["A" :route/link '?v] db {})]
    (assert-eq "match-fact: bound entity"
               [{'?v "B"}] (vec envs)))

  (let [envs (worker/match-fact ['?e :route/link "C"] db {})]
    (assert-eq "match-fact: bound value"
               [{'?e "B"}] (vec envs))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 7: solve-clause — direct triple pattern
;; ═══════════════════════════════════════════════════════════════════════════════

(let [facts [["A" :route/link "B"]
             ["B" :route/link "C"]]
      db (worker/build-indexes facts)]

  (let [envs (worker/solve-clause ['?x :route/link '?y] [] db {} #{})]
    (assert-eq "solve-clause triple: finds two bindings"
               2 (count envs))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 8: Rule evaluation — basic
;; ═══════════════════════════════════════════════════════════════════════════════

(let [facts [["A" :route/link "B"]
             ["B" :route/link "C"]]
      db (worker/build-indexes facts)
      ;; Rule: (path ?x ?y) :- [?x :route/link ?y]
      ;; Rule: (path ?x ?y) :- [?x :route/link ?z], (path ?z ?y)
      rules [[(list 'path '?x '?y) ['?x :route/link '?y]]
             [(list 'path '?x '?y) ['?x :route/link '?z] (list 'path '?z '?y)]]]

  ;; Direct link A→B
  (let [envs (worker/solve-clause (list 'path "A" '?y) rules db {} #{})]
    (assert-true "rule: path A ?y finds B and C"
                 (= (set (map #(get % '?y) envs)) #{"B" "C"})))

  ;; No path from C
  (let [envs (worker/solve-clause (list 'path "C" '?y) rules db {} #{})]
    (assert-eq "rule: path C ?y finds nothing"
               0 (count envs))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 9: query-datalog — end-to-end
;; ═══════════════════════════════════════════════════════════════════════════════

(let [facts [["A" :route/link "B"]
             ["B" :route/link "C"]
             ["C" :route/link "D"]]
      db (worker/build-indexes facts)
      rules [[(list 'path '?x '?y) ['?x :route/link '?y]]
             [(list 'path '?x '?y) ['?x :route/link '?z] (list 'path '?z '?y)]]
      q-map {:find ['?y]
             :where [(list 'path '?x '?y)]}]

  ;; Query: find all ?y reachable from any ?x
  (let [results (worker/query-datalog q-map db rules {'?x "A"})]
    (assert-eq "query-datalog: reachable from A"
               #{["B"] ["C"] ["D"]} (set results)))

  ;; Query with fully open variables
  (let [results (worker/query-datalog q-map db rules {})]
    (assert-true "query-datalog: all paths"
                 (>= (count results) 3))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 10: query-datalog — multi-clause join
;; ═══════════════════════════════════════════════════════════════════════════════

(let [facts [["alice" :name "Alice"]
             ["alice" :age 30]
             ["bob"   :name "Bob"]
             ["bob"   :age 25]]
      db (worker/build-indexes facts)
      q-map {:find ['?name '?age]
             :where [['?e :name '?name]
                     ['?e :age '?age]]}]
  (let [results (worker/query-datalog q-map db [] {})]
    (assert-eq "query-datalog join: name+age pairs"
               #{["Alice" 30] ["Bob" 25]} (set results))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 11: init-datascript — integrated test
;; ═══════════════════════════════════════════════════════════════════════════════

(let [datoms [{:entity 1 :attribute "name" :value "Alice"}
              {:entity 2 :attribute "name" :value "Bob"}
              {:entity 1 :attribute "friend" :value 2}]
      ds (worker/init-datascript datoms)]
  (assert-true "init-datascript: has :facts atom"
               (instance? clojure.lang.Atom (:facts ds)))
  (assert-true "init-datascript: has :indexes atom"
               (instance? clojure.lang.Atom (:indexes ds)))
  (assert-true "init-datascript: facts include base data"
               (some (fn [[e a v]] (and (= e 1) (= a :name) (= v "Alice")))
                     @(:facts ds)))
  ;; Verify indexes are populated
  (let [idx @(:indexes ds)]
    (assert-true "init-datascript: EAV index populated"
                 (seq (:eav idx)))
    (assert-true "init-datascript: AVE index populated"
                 (seq (:ave idx)))
    (assert-true "init-datascript: AEV index populated"
                 (seq (:aev idx)))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 12: Cycle detection in rules
;; ═══════════════════════════════════════════════════════════════════════════════

(let [facts [["A" :link "B"]
             ["B" :link "A"]]  ;; cycle!
      db (worker/build-indexes facts)
      rules [[(list 'reach '?x '?y) ['?x :link '?y]]
             [(list 'reach '?x '?y) ['?x :link '?z] (list 'reach '?z '?y)]]]
  (let [results (worker/query-datalog {:find ['?y] :where [(list 'reach '?x '?y)]}
                                       db rules {'?x "A"})]
    (assert-true "cycle detection: terminates with results"
                 (seq results))
    (assert-true "cycle detection: finds B"
                 (some #(= % ["B"]) results))
    (assert-true "cycle detection: finds A (via cycle)"
                 (some #(= % ["A"]) results))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Test 13: parse-query
;; ═══════════════════════════════════════════════════════════════════════════════

(let [q (worker/parse-query "[:find ?y :in $ % ?x :where (path ?x ?y)]")]
  (assert-eq "parse-query :find" ['?y] (:find q))
  (assert-eq "parse-query :in" ['$ '% '?x] (:in q))
  (assert-eq "parse-query :where count" 1 (count (:where q))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Phase 1 Tests: Clause Reordering, Filters, Negation-as-Failure
;; ═══════════════════════════════════════════════════════════════════════════════

;; Test 14: Clause Reordering Heuristic
(let [clauses '[ [?e :age ?age] [?e :name ?name] ]
      ordered (worker/reorder-clauses clauses #{'?name})]
  (assert-eq "reorder-clauses: bound variable narrows search space first"
             '[[?e :name ?name] [?e :age ?age]]
             (vec ordered)))

(let [clauses '[ [(> ?age 25)] [?e :age ?age] [?e :name ?name] ]
      ordered (worker/reorder-clauses clauses #{'?name})]
  (assert-eq "reorder-clauses: filter deferred until variables are bound"
             '[[?e :name ?name] [?e :age ?age] [(> ?age 25)]]
             (vec ordered)))

;; Test 15: Filter Expression evaluation
(assert-true "eval-filter: basic gt" (worker/eval-filter '(> ?x 20) {'?x 25}))
(assert-false "eval-filter: basic gt false" (worker/eval-filter '(> ?x 20) {'?x 15}))
(assert-true "eval-filter: basic lt" (worker/eval-filter '(< ?x 20) {'?x 15}))
(assert-true "eval-filter: basic and" (worker/eval-filter '(and (> ?x 10) (< ?x 20)) {'?x 15}))
(assert-true "eval-filter: string compare" (worker/eval-filter '(> ?name "Alice") {'?name "Bob"}))

;; Test 16: E2E Datalog query with filters
(let [facts [["alice" :name "Alice"]
             ["alice" :age 30]
             ["bob"   :name "Bob"]
             ["bob"   :age 20]]
      db (worker/build-indexes facts)
      q-map {:find ['?name]
             :where [['?e :name '?name]
                     ['?e :age '?age]
                     '[(> ?age 25)]]}]
  (let [results (worker/query-datalog q-map db [] {})]
    (assert-eq "query-datalog filter: only Alice is > 25"
               #{["Alice"]} (set results))))

;; Test 17: E2E Datalog query with negation
(let [facts [["alice" :name "Alice"]
             ["alice" :blocked true]
             ["bob"   :name "Bob"]]
      db (worker/build-indexes facts)
      q-map {:find ['?name]
             :where [['?e :name '?name]
                     '(not [?e :blocked true])]}]
  (let [results (worker/query-datalog q-map db [] {})]
    (assert-eq "query-datalog negation: only Bob is not blocked"
               #{["Bob"]} (set results))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Phase 2 Tests: Aggregate Functions, Scoring / Weighted Union
;; ═══════════════════════════════════════════════════════════════════════════════

;; Test 18: aggregate-values helpers
(assert-eq "aggregate-values: count" 3 (worker/aggregate-values 'count [10 20 30]))
(assert-eq "aggregate-values: sum" 60 (worker/aggregate-values 'sum [10 20 30]))
(assert-eq "aggregate-values: min" 10 (worker/aggregate-values 'min [30 10 20]))
(assert-eq "aggregate-values: max" 30 (worker/aggregate-values 'max [30 10 20]))
(assert-eq "aggregate-values: avg" 20.0 (worker/aggregate-values 'avg [10 20 30]))
(assert-eq "aggregate-values: median odd" 20 (worker/aggregate-values 'median [30 10 20]))
(assert-eq "aggregate-values: median even" 25.0 (worker/aggregate-values 'median [10 20 30 40]))

;; Test 19: E2E Datalog query with aggregates (single group)
(let [facts [["alice" :age 30]
             ["bob"   :age 20]
             ["charlie" :age 40]]
      db (worker/build-indexes facts)
      q-map {:find ['(count ?e) '(sum ?age) '(avg ?age) '(median ?age)]
             :where [['?e :age '?age]]}]
  (let [results (worker/query-datalog q-map db [] {})]
    (assert-eq "query-datalog aggregates: single group metrics"
               [[3 90 30.0 30]] results)))

;; Test 20: E2E Datalog query with aggregates and group keys
(let [facts [["alice" :type "dev"]
             ["alice" :age 30]
             ["bob"   :type "dev"]
             ["bob"   :age 20]
             ["charlie" :type "design"]
             ["charlie" :age 40]]
      db (worker/build-indexes facts)
      q-map {:find ['?type '(count ?e) '(sum ?age)]
             :where [['?e :type '?type]
                     ['?e :age '?age]]}]
  (let [results (worker/query-datalog q-map db [] {})]
    (assert-eq "query-datalog aggregates: grouped by type"
               #{["dev" 2 50] ["design" 1 40]} (set results))))

;; Test 21: Weighted Union and normalization strategy
(let [res-a [{:entity 1 :score 10.0} {:entity 2 :score 20.0}]
      res-b [{:entity 2 :score 5.0} {:entity 3 :score 15.0}]
      union-norm (worker/weighted-union res-a res-b 1.0 1.0 :min-max)
      union-none (worker/weighted-union res-a res-b 1.0 2.0 :none)]
  
  (assert-eq "weighted-union :min-max: correct scores and sorting"
             [{:entity 2 :score 1.0} {:entity 3 :score 1.0} {:entity 1 :score 0.0}]
             union-norm)
  (assert-eq "weighted-union :none: correct scores and sorting"
             [{:entity 2 :score 30.0} {:entity 3 :score 30.0} {:entity 1 :score 10.0}]
             union-none))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Phase 3 Tests: BFS Shortest Path, Cosine Similarity, LRU Query Cache
;; ═══════════════════════════════════════════════════════════════════════════════

;; Test 22: BFS Shortest Path E2E Datalog
(let [facts [["A" :link "B"]
             ["B" :link "C"]
             ["B" :link "D"]
             ["D" :link "E"]]
      db (worker/build-indexes facts)
      q-map-1 {:find ['?path '?cost]
               :where ['(shortest-path "A" "E" :link ?path ?cost)]}
      q-map-2 {:find ['?to '?path]
               :where ['(shortest-path "A" ?to :link ?path _)]}
      q-map-3 {:find ['?path]
               :where ['(shortest-path "A" "C" :link ?path _ 1)]}] ;; max depth 1
  
  (assert-eq "shortest-path: E2E path A -> E"
             [[["A" "B" "D" "E"] 3]]
             (worker/query-datalog q-map-1 db [] {}))
  
  (assert-eq "shortest-path: E2E target variable from A"
             #{["A" ["A"]] ["B" ["A" "B"]] ["C" ["A" "B" "C"]] ["D" ["A" "B" "D"]] ["E" ["A" "B" "D" "E"]]}
             (set (worker/query-datalog q-map-2 db [] {})))
             
  (assert-eq "shortest-path: depth constraint restricts A -> C"
             []
             (worker/query-datalog q-map-3 db [] {})))

;; Test 23: Cosine Similarity
(assert-true "cosine-similarity: identical direction"
             (< (Math/abs (- 1.0 (worker/cosine-similarity [1.0 2.0] [2.0 4.0]))) 1e-9))

(assert-true "cosine-similarity: orthogonal vectors"
             (< (Math/abs (- 0.0 (worker/cosine-similarity [1.0 0.0] [0.0 1.0]))) 1e-9))

;; Test 24: LRU Query Cache & Self-Invalidation
(let [facts [["A" :val 10] ["B" :val 20]]
      db (worker/build-indexes facts)
      q-map {:find ['?v] :where [['?e :val '?v] '(> ?v 15)]}]
  
  ;; Clear cache
  (reset! worker/query-cache {})
  
  ;; Query first time -> caches
  (let [res1 (worker/query-datalog q-map db [] {})]
    (assert-eq "query-cache first run" [[20]] res1)
    (assert-eq "query-cache count is 1" 1 (count @worker/query-cache)))
    
  ;; Query second time -> cache hit
  (let [res2 (worker/query-datalog q-map db [] {})]
    (assert-eq "query-cache second run (cached)" [[20]] res2)
    (assert-eq "query-cache count remains 1" 1 (count @worker/query-cache)))
    
  ;; transacting new facts should change (:facts db) and bypass cache
  (let [facts' (conj facts ["C" :val 30])
        db' (worker/build-indexes facts')]
    (let [res3 (worker/query-datalog q-map db' [] {})]
      (assert-eq "query-cache new database facts (cache bypass)"
                 #{[20] [30]} (set res3))
      (assert-eq "query-cache count increases to 2" 2 (count @worker/query-cache)))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Phase 4 Tests: Reachable, Cycle Detection, Topological Sort
;; ═══════════════════════════════════════════════════════════════════════════════

;; Test 25: BFS Reachable (Transitive Closure)
(let [facts [["A" :link "B"]
             ["B" :link "C"]]
      db (worker/build-indexes facts)
      q-map {:find ['?node] :where ['(reachable "A" :link ?node)]}]
  (assert-eq "reachable: find all reachable from A"
             #{["A"] ["B"] ["C"]}
             (set (worker/query-datalog q-map db [] {}))))

;; Test 26: DFS Cycle Detection
(let [facts [["A" :link "B"]
             ["B" :link "C"]
             ["C" :link "A"]
             ["D" :link "E"]]
      db (worker/build-indexes facts)
      q-map {:find ['?cycle] :where ['(cycle-detect :link ?cycle)]}
      results (worker/query-datalog q-map db [] {})
      first-cycle (first (first results))
      cycle-set (set first-cycle)]
  (assert-eq "cycle-detect: count of cycles found" 1 (count results))
  ;; Cycle can start at A, B or C depending on DFS start, but must be A, B, C
  (assert-eq "cycle-detect: cycle vertices match" #{"A" "B" "C"} cycle-set))

;; Test 27: Kahn's Topological Sort
(let [facts [["A" :link "B"]
             ["B" :link "C"]
             ["D" :link "B"]]
      db (worker/build-indexes facts)
      q-map {:find ['?order] :where ['(topological-sort :link ?order)]}
      results (worker/query-datalog q-map db [] {})
      order (first (first results))]
  (assert-eq "topological-sort: unique sort returned" 1 (count results))
  ;; Valid orders are ["A" "D" "B" "C"] or ["D" "A" "B" "C"]
  (assert-true "topological-sort: ordering is valid"
               (or (= order ["A" "D" "B" "C"])
                   (= order ["D" "A" "B" "C"]))))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Phase 5 Tests: PageRank, Tarjan's SCC, Bloom Filter
;; ═══════════════════════════════════════════════════════════════════════════════

;; Test 28: PageRank Centrality
(let [facts [["A" :link "B"]
             ["B" :link "C"]
             ["C" :link "A"]]
      db (worker/build-indexes facts)
      q-map {:find ['?entity '?rank]
             :where ['(pagerank ?entity :link ?rank 0.85 10)]}
      results (worker/query-datalog q-map db [] {})]
  (assert-eq "pagerank: count of nodes ranked" 3 (count results))
  ;; Every node in a symmetrical cycle should have rank = 1/3 (0.333333333)
  (doseq [[ent rank] results]
    (assert-true (str "pagerank: rank for " ent " is close to 0.3333")
                 (< (Math/abs (- 0.33333333 rank)) 1e-6))))

;; Test 29: Tarjan's Strongly Connected Components
(let [facts [["A" :link "B"]
             ["B" :link "C"]
             ["C" :link "A"]
             ["C" :link "D"]
             ["D" :link "E"]
             ["E" :link "D"]]
      db (worker/build-indexes facts)
      q-map {:find ['?entity '?cid] :where ['(scc :link ?entity ?cid)]}
      results (worker/query-datalog q-map db [] {})
      comp-map (into {} results)]
  (assert-eq "scc: total vertices classified" 5 (count comp-map))
  (assert-eq "scc: A, B, C in same component" (get comp-map "A") (get comp-map "B"))
  (assert-eq "scc: B, C in same component" (get comp-map "B") (get comp-map "C"))
  (assert-eq "scc: D, E in same component" (get comp-map "D") (get comp-map "E"))
  (assert-true "scc: different components" (not= (get comp-map "A") (get comp-map "D"))))

;; Test 30: Bloom Filter
(let [filter (worker/bloom-create 100 3)
      filter' (worker/bloom-insert filter "hello")]
  (assert-true "bloom: contains inserted key" (worker/bloom-might-contain? filter' "hello"))
  (assert-false "bloom: does not contain non-inserted key" (worker/bloom-might-contain? filter' "world")))

;; ═══════════════════════════════════════════════════════════════════════════════
;; Report
;; ═══════════════════════════════════════════════════════════════════════════════

(println "\n══════════════════════════════════════")
(println "  Indexed Datalog Engine Test Report")
(println "══════════════════════════════════════")
(doseq [[status name] @test-names]
  (println (str (if (= status :pass) "  ✅ " "  ❌ ") name)))
(println "──────────────────────────────────────")
(println (str "  PASSED: " @pass-count " | FAILED: " @fail-count))
(println "══════════════════════════════════════\n")

(when (pos? @fail-count)
  (System/exit 1))
