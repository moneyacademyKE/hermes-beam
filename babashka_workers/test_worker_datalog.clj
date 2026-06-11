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
