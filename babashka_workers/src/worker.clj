(ns worker
  (:require [clojure.core.async :as async]
            [cheshire.core :as json]
            [babashka.http-client :as http]
            [babashka.process :as p]
            [clojure.java.io :as io]
            [clojure.edn :as edn]
            [clojure.walk :as walk]
            [clojure.set :as set])
  (:import [java.net UnixDomainSocketAddress StandardProtocolFamily]
           [java.nio.channels SocketChannel]
           [java.nio ByteBuffer]
           [java.nio.file Files Paths]))

(def tool-schemas
  [{:type "function"
    :function {:name "run_command"
               :description "Execute a local shell or babashka (bb) command. CRITICAL: ALWAYS use Babashka (bb) for scripting. NEVER invoke Python."
               :parameters {:type "object"
                            :properties {:command {:type "string"}}
                            :required ["command"]}}}
   {:type "function"
    :function {:name "read_file"
               :description "Read a local file"
               :parameters {:type "object"
                            :properties {:path {:type "string"}}
                            :required ["path"]}}}
   {:type "function"
    :function {:name "write_file"
               :description "Write to a local file"
               :parameters {:type "object"
                            :properties {:path {:type "string"}
                                         :content {:type "string"}}
                            :required ["path" "content"]}}}
   {:type "function"
    :function {:name "fetch_url"
               :description "Fetch content from a URL via GET"
               :parameters {:type "object"
                            :properties {:url {:type "string"}}
                            :required ["url"]}}}
   {:type "function"
    :function {:name "bb_eval"
               :description "Evaluate a Babashka/Clojure expression inline for scripting tasks. Use INSTEAD of Python."
               :parameters {:type "object"
                            :properties {:code {:type "string" :description "Clojure/Babashka code to evaluate"}}
                            :required ["code"]}}}
   {:type "function"
    :function {:name "run_in_docker"
               :description "Execute a Babashka script in a short-lived Docker container for isolation. Falls back to native bb if Docker unavailable. NEVER use Python."
               :parameters {:type "object"
                            :properties {:image {:type "string" :description "Docker image to use, e.g. babashka/babashka:latest"}
                                         :code {:type "string" :description "Clojure/Babashka code to execute"}}
                            :required ["image" "code"]}}}
   {:type "function"
    :function {:name "query_datalog"
               :description "Query the in-memory database using Clojure Datalog query syntax. CRITICAL: query MUST be a vector starting with [:find ...] (e.g. '[:find ?y :in $ ?x :where [?x :route/link ?y]]'). For recursive rules, specify them inside the :where block or define them dynamically. To audit an unknown schema, use wildcards (e.g. '[:find ?a ?v :where [?e ?a ?v]]' or '[?e :active _]'). Do NOT search the web or clone external codebases to resolve database details; use query_datalog directly."
               :parameters {:type "object"
                            :properties {:query {:type "string"}
                                         :inputs {:type "array" :items {:type "string"}}}
                            :required ["query" "inputs"]}}}
   {:type "function"
    :function {:name "transact_datalog"
               :description "Transact new facts to the in-memory DataScript database. Input: list of EAV triples (e.g. '[[\"A\" \"route/link\" \"B\"]]')"
               :parameters {:type "object"
                            :properties {:facts {:type "array" :items {:type "array" :items {:type "string"}}}}
                            :required ["facts"]}}}
   {:type "function"
    :function {:name "run_sandboxed_command"
               :description "Runs a shell command under a strict OS-level sandbox (macOS sandbox-exec). Write operations are only permitted within allowed_write_paths (defaults to /tmp and workspace)."
               :parameters {:type "object"
                            :properties {:command {:type "string" :description "Shell command to execute"}
                                         :allowed_write_paths {:type "array" :items {:type "string"} :description "Optional list of additional directories permitted for writing"}}
                            :required ["command"]}}}
   {:type "function"
    :function {:name "get_repl_state"
               :description "List all defined variables and functions in the persistent sandbox-user namespace."
               :parameters {:type "object"
                            :properties {}}}}])

(defn connect-uds [path]
  (let [addr (UnixDomainSocketAddress/of path)
        channel (SocketChannel/open StandardProtocolFamily/UNIX)]
    (.connect channel addr)
    channel))

(defn send-msg [channel msg]
  (let [bytes (.getBytes msg "UTF-8")
        buf (ByteBuffer/wrap bytes)]
    (.write channel buf)))

(defn send-telemetry [channel status]
  (when channel
    (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                             :method "telemetry"
                                             :params {:status status
                                                      :memory (.freeMemory (Runtime/getRuntime))}}))))

(defn- env-long [name default]
  (try
    (if-let [v (System/getenv name)]
      (Long/parseLong v)
      default)
    (catch Exception _ default)))

(defn- env-list [name]
  (some-> (System/getenv name)
          (clojure.string/split #",")
          (->> (map clojure.string/trim)
               (remove clojure.string/blank?)
               set)))

(defn- log-event [level event data]
  (binding [*out* *err*]
    (println (json/generate-string (merge {:level level
                                           :event event
                                           :ts (str (java.time.Instant/now))}
                                          data)))))

(defn docker-available? []
  (try
    (let [{:keys [exit]} (p/sh "docker" "info")]
      (= 0 exit))
    (catch Exception _ false)))

(defn with-retries* [max-retries delay-ms f]
  (loop [retries max-retries
         curr-delay delay-ms]
    (let [res (try {:ok (f)}
                   (catch Exception e
                     (if (pos? retries)
                       {:retry e}
                       (throw e))))]
      (if (contains? res :ok)
        (:ok res)
        (do
          (Thread/sleep curr-delay)
          (recur (dec retries) (* curr-delay 2)))))))

(defn bb-available? []
  (try
    (let [{:keys [exit]} (p/sh "bb" "--version")]
      (= 0 exit))
    (catch Exception _ false)))

(defn recv-tool-response
  ([channel expected-id]
   (recv-tool-response channel expected-id (env-long "HERMES_WORKER_TOOL_TIMEOUT_MS" 30000)))
  ([channel expected-id timeout-ms]
   (let [buf (ByteBuffer/allocate 4096)
         deadline (+ (System/currentTimeMillis) timeout-ms)
         was-blocking (.isBlocking channel)]
     (try
       (.configureBlocking channel false)
       (loop [acc ""]
         (when (> (System/currentTimeMillis) deadline)
           (throw (Exception. (str "Timed out waiting " timeout-ms "ms for delegated tool response id " expected-id))))
       (if (clojure.string/includes? acc "\n")
         (let [lines (clojure.string/split acc #"\n")
               line (first lines)
               remaining (clojure.string/join "\n" (rest lines))]
          (let [parsed (try {:ok (json/parse-string line true)}
                            (catch Exception _ {:err true}))]
            (if (:err parsed)
              (recur remaining)
              (let [resp (:ok parsed)]
                (if (= (:id resp) expected-id)
                  (if-let [err (:error resp)]
                    (throw (Exception. (str "Gleam tool error: " (:message err))))
                    (:result resp))
                  (recur remaining))))))
         (do
           (.clear buf)
           (let [bytes-read (.read channel buf)]
             (cond
               (pos? bytes-read)
               (do
                 (.flip buf)
                 (let [bytes (byte-array (.remaining buf))]
                   (.get buf bytes)
                   (recur (str acc (String. bytes "UTF-8")))))

               (= bytes-read 0)
               (do
                 (Thread/sleep 25)
                 (recur acc))

               :else
               (throw (Exception. "Socket closed while waiting for tool response")))))))
       (finally
         (.configureBlocking channel was-blocking))))))

(defn merge-tool-schemas [gleam-tools]
  (let [native-names (set (map #(get-in % [:function :name]) tool-schemas))
        filtered-gleam (filter #(not (contains? native-names (get-in % [:function :name])))
                               gleam-tools)]
    (vec (concat tool-schemas filtered-gleam))))

;; ─── Indexed Datalog Engine (ported from aarondb) ─────────────────────────────
;;
;; Architecture:
;;   1. Triple Indexing  — EAV, AVE, AEV hash-maps for O(1) lookups
;;   2. Term Unification — explicit variable? / constant? with recursive binding
;;   3. Index Lookup     — pattern-driven index selection (aarondb strategy)
;;   4. Rule Evaluation  — fresh-var renaming + cycle-guarded recursion
;;
;; Zero external dependencies. Runs natively on Babashka.
;; ──────────────────────────────────────────────────────────────────────────────

;; ── helpers ──────────────────────────────────────────────────────────────────

(defn- variable? [x]
  (and (symbol? x) (clojure.string/starts-with? (name x) "?")))

(defn- clean-symbol [s]
  (if (and (string? s) (clojure.string/starts-with? s "?"))
    (symbol s)
    s))

(defn- rule-name-for [attr]
  (symbol (clojure.string/replace attr #"/" "-")))

;; ── query parser ─────────────────────────────────────────────────────────────

(defn parse-query [query-str]
  (let [q (edn/read-string query-str)]
    (loop [rem q current-kw nil acc {:find [] :in [] :where []}]
      (if (empty? rem)
        acc
        (let [x (first rem)]
          (if (keyword? x)
            (recur (rest rem) x acc)
            (recur (rest rem) current-kw (if current-kw (update acc current-kw conj x) acc))))))))

;; ── triple indexing (ported from aarondb/index.gleam) ────────────────────────
;;
;; build-indexes takes a flat vector of [e a v] triples and builds three
;; hash-map indexes that mirror aarondb's EAVT / AEVT / AVET strategy:
;;
;;   :eav  — {entity → {attr → #{values}}}      (primary entity lookup)
;;   :ave  — {attr → {value → #{entities}}}      (reverse value lookup)
;;   :aev  — {attr → {entity → #{values}}}       (attribute-first scan)
;;   :facts — the raw triples vector              (fallback linear scan)
;;
;; All three are built in a single O(N) pass over the facts.

(defn build-indexes
  "Build EAV/AVE/AEV triple indexes from a flat vector of [e a v] triples.
   Returns {:eav {...} :ave {...} :aev {...} :facts facts}."
  [facts]
  (reduce
   (fn [{:keys [eav ave aev] :as acc} [e a v]]
     (-> acc
         ;; EAV: entity → attr → #{values}
         (assoc-in [:eav e a] (conj (get-in eav [e a] #{}) v))
         ;; AVE: attr → value → #{entities}
         (assoc-in [:ave a v] (conj (get-in ave [a v] #{}) e))
         ;; AEV: attr → entity → #{values}
         (assoc-in [:aev a e] (conj (get-in aev [a e] #{}) v))))
   {:eav {} :ave {} :aev {} :facts facts}
   facts))

;; ── term unification ─────────────────────────────────────────────────────────

(defn resolve-term
  "Chase a variable through the binding environment until it reaches
   a ground value or an unbound variable. Cycle-safe via `seen` set."
  [term env]
  (loop [t term seen #{}]
    (if (variable? t)
      (if (seen t) t
          (if-let [bound (get env t)]
            (recur bound (conj seen t))
            t))
      t)))

(defn unify
  "Attempt to unify pattern `p` with term `t` under environment `env`.
   Returns extended env on success, nil on failure."
  [p t env]
  (let [p' (resolve-term p env)
        t' (resolve-term t env)]
    (cond
      (variable? p') (assoc env p' t')
      (variable? t') (assoc env t' p')
      (= p' t')      env
      :else           nil)))

;; ── index-driven pattern matching (aarondb strategy) ─────────────────────────
;;
;; Instead of scanning all facts for every clause, `index-lookup` selects the
;; most selective index based on which parts of the pattern are already bound:
;;
;;   Pattern shape              Index used           Complexity
;;   ─────────────────────────  ───────────────────  ──────────
;;   [bound-e  bound-a  ?v]     EAV[e][a]            O(1)
;;   [?e       bound-a  bound-v] AVE[a][v]           O(1)
;;   [?e       bound-a  ?v]     AEV[a]               O(entities)
;;   [bound-e  ?a       ?v]     EAV[e]               O(attrs)
;;   [?e       ?a       ?v]     full scan            O(N)

(defn- match-from-triples
  "Unify pattern [pe pa pv] against each triple, returning extended envs."
  [pe pa pv triples env]
  (keep (fn [[e a v]]
          (when-let [env1 (unify pe e env)]
            (when-let [env2 (unify pa a env1)]
              (if (= pv '_)
                env2
                (unify pv v env2)))))
        triples))

(defn index-lookup
  "Use the most selective index to resolve a [pe pa pv] pattern."
  [db pe pa pv env]
  (let [re (resolve-term pe env)
        ra (resolve-term pa env)
        rv (if (= pv '_) '_ (resolve-term pv env))
        e-bound? (not (variable? re))
        a-bound? (not (variable? ra))
        v-bound? (and (not= rv '_) (not (variable? rv)))]
    (cond
      ;; Case 1: entity + attribute bound → EAV[e][a] → set of values
      (and e-bound? a-bound?)
      (let [vals (get-in (:eav db) [re ra])]
        (if vals
          (if v-bound?
            ;; Check membership O(1) in the set
            (if (contains? vals rv)
              [env]  ;; all three match, env is already complete
              [])
            ;; v is a variable — bind it to each value
            (keep (fn [v] (unify pv v env)) vals))
          []))

      ;; Case 2: attribute + value bound → AVE[a][v] → set of entities
      (and a-bound? v-bound?)
      (let [entities (get-in (:ave db) [ra rv])]
        (if entities
          (keep (fn [e] (unify pe e env)) entities)
          []))

      ;; Case 3: attribute bound → AEV[a] → {entity → values}
      a-bound?
      (let [e-map (get (:aev db) ra)]
        (if e-map
          (mapcat (fn [[e vals]]
                    (when-let [env1 (unify pe e env)]
                      (if (= pv '_)
                        [env1]
                        (keep (fn [v] (unify pv v env1)) vals))))
                  e-map)
          []))

      ;; Case 4: entity bound → EAV[e] → {attr → values}
      e-bound?
      (let [a-map (get (:eav db) re)]
        (if a-map
          (mapcat (fn [[a vals]]
                    (when-let [env1 (unify pa a env)]
                      (if (= pv '_)
                        [env1]
                        (keep (fn [v] (unify pv v env1)) vals))))
                  a-map)
          []))

      ;; Case 5: nothing bound → full scan
      :else
      (match-from-triples pe pa pv (:facts db) env))))

(defn match-fact
  "Match a clause pattern against the indexed database.
   Falls back to linear scan only when no index can help."
  [clause db env]
  (if (< (count clause) 2)
    []
    (let [pe (first clause)
          pa (second clause)
          pv (if (>= (count clause) 3) (nth clause 2) '_)]
      (index-lookup db pe pa pv env))))

;; ── rule evaluation ──────────────────────────────────────────────────────────

(defn rename-vars
  "Alpha-rename all variables in a rule to avoid capture.
   Each variable ?x becomes ?x_<suffix>."
  [rule suffix]
  (clojure.walk/postwalk
   (fn [x]
     (if (variable? x)
       (symbol (str (name x) "_" suffix))
       x))
   rule))

(def rule-counter (atom 0))

(declare solve-clause)

;; ── query planner & clause reordering (P0) ───────────────────────────────────

(defn clause-vars
  "Recursively find all variables (symbols starting with ?) in a clause."
  [clause]
  (cond
    (variable? clause) #{clause}
    (coll? clause) (into #{} (mapcat clause-vars clause))
    :else #{}))

(defn estimate-cost
  "Estimate the selectivity cost of a clause based on currently bound variables."
  [clause bound-vars]
  (cond
    ;; Negative clause: (not [?e :blocked true]) or [not [?e :blocked true]]
    (and (sequential? clause) (= (first clause) 'not))
    (let [inner (second clause)
          vars (clause-vars inner)]
      (if (clojure.set/subset? vars bound-vars) 5 5000))

    ;; Filter clause: [(> ?a 25)] or (or ...)
    (let [first-el (if (sequential? clause) (first clause) clause)]
      (and (sequential? first-el) (contains? #{'> '< '>= '<= '= '!= 'not= 'and 'or} (first first-el))))
    (let [vars (clause-vars clause)]
      (if (clojure.set/subset? vars bound-vars) 2 8000))

    ;; Also direct list starting with comparison operator
    (and (sequential? clause) (contains? #{'> '< '>= '<= '= '!= 'not= 'and 'or} (first clause)))
    (let [vars (clause-vars clause)]
      (if (clojure.set/subset? vars bound-vars) 2 8000))

    ;; Graph ShortestPath
    (and (seq? clause) (= (first clause) 'shortest-path))
    (let [[_ from to] clause
          from-bound? (or (not (variable? from)) (contains? bound-vars from))
          to-bound? (or (not (variable? to)) (contains? bound-vars to))]
      (if (and from-bound? to-bound?) 500 9000))

    ;; Graph Reachable
    (and (seq? clause) (= (first clause) 'reachable))
    (let [[_ from] clause
          from-bound? (or (not (variable? from)) (contains? bound-vars from))]
      (if from-bound? 50 9000))

    ;; Rule application (list starting with anything else)
    (seq? clause)
    (let [[_ he hv] clause
          e-bound? (or (not (variable? he)) (contains? bound-vars he))
          v-bound? (or (not (variable? hv)) (contains? bound-vars hv))]
      (cond
        (and e-bound? v-bound?) 100
        e-bound?                200
        v-bound?                500
        :else                   5000))

    ;; Positive triple pattern [e a v]
    (vector? clause)
    (let [[e _ v] clause
          e-bound? (or (not (variable? e)) (contains? bound-vars e))
          v-bound? (or (not (variable? v)) (contains? bound-vars v))]
      (cond
        (and e-bound? v-bound?) 1
        e-bound?                10
        v-bound?                100
        :else                   1000))

    :else 9999))

(defn reorder-clauses
  "Greedily reorder clauses based on selectivity cost given a set of bound variables."
  [clauses bound-vars]
  (loop [remaining clauses
         bound bound-vars
         acc []]
    (if (empty? remaining)
      acc
      (let [best (apply min-key #(estimate-cost % bound) remaining)
            next-remaining (remove #(= % best) remaining)
            new-bound (clojure.set/union bound (clause-vars best))]
        (recur next-remaining new-bound (conj acc best))))))

;; ── filter evaluator (P0) ────────────────────────────────────────────────────

(defn eval-filter
  "Recursively evaluate comparison and logical filter expressions."
  [expr env]
  (let [expr (if (and (sequential? expr) (sequential? (first expr))) (first expr) expr)]
    (if (sequential? expr)
      (let [op (first expr)
            args (rest expr)
            resolve-arg (fn [x] (let [r (resolve-term x env)]
                                  (if (variable? r)
                                    (throw (Exception. (str "Unbound variable in filter: " r)))
                                    r)))]
        (case op
          and (every? #(eval-filter % env) args)
          or  (some #(eval-filter % env) args)
          (let [resolved-args (map resolve-arg args)
                arg1 (first resolved-args)
                arg2 (second resolved-args)]
            (case op
              =    (= arg1 arg2)
              !=   (not= arg1 arg2)
              not= (not= arg1 arg2)
              >    (cond
                     (and (number? arg1) (number? arg2)) (> arg1 arg2)
                     (and (string? arg1) (string? arg2)) (pos? (compare arg1 arg2))
                     :else (throw (Exception. (str "Cannot compare " arg1 " and " arg2))))
              <    (cond
                     (and (number? arg1) (number? arg2)) (< arg1 arg2)
                     (and (string? arg1) (string? arg2)) (neg? (compare arg1 arg2))
                     :else (throw (Exception. (str "Cannot compare " arg1 " and " arg2))))
              >=   (cond
                     (and (number? arg1) (number? arg2)) (>= arg1 arg2)
                     (and (string? arg1) (string? arg2)) (not (neg? (compare arg1 arg2)))
                     :else (throw (Exception. (str "Cannot compare " arg1 " and " arg2))))
              <=   (cond
                     (and (number? arg1) (number? arg2)) (<= arg1 arg2)
                     (and (string? arg1) (string? arg2)) (not (pos? (compare arg1 arg2)))
                     :else (throw (Exception. (str "Cannot compare " arg1 " and " arg2))))
              (throw (Exception. (str "Unknown operator: " op)))))))
      expr)))

;; ── negation-as-failure helpers (P0) ─────────────────────────────────────────

(defn negative-clause? [clause]
  (and (sequential? clause) (= (first clause) 'not)))

(defn extract-negative-inner [clause]
  (second clause))

(defn filter-clause? [clause]
  (or (and (sequential? clause) (contains? #{'> '< '>= '<= '= '!= 'not= 'and 'or} (first clause)))
      (and (sequential? clause)
           (sequential? (first clause))
           (contains? #{'> '< '>= '<= '= '!= 'not= 'and 'or} (first (first clause))))))

(defn solve-negative [inner-clause rules db env visited]
  (let [results (solve-clause inner-clause rules db env visited)]
    (if (empty? results)
      [env]
      [])))

(defn solve-rule
  "Evaluate a rule-application clause against all matching rules.
   Uses cycle detection via the `visited` set to prevent infinite loops."
  [clause rules db env visited]
  (if (< (count clause) 3)
    []
    (let [rname (first clause)
          re    (second clause)
          rv    (nth clause 2)
          evaled-re (resolve-term re env)
          evaled-rv (resolve-term rv env)
          goal  [rname evaled-re evaled-rv]]
      (if (contains? visited goal)
        []
        (let [visited' (conj visited goal)
              matching (filter (fn [[head & _]]
                                 (and (= (first head) rname)
                                      (= (count head) 3)))
                               rules)]
          (mapcat
           (fn [rule]
             (let [renamed (rename-vars rule (swap! rule-counter inc))
                   [_ he hv] (first renamed)
                   body (rest renamed)]
               (if-let [env1 (unify he re env)]
                 (if-let [env2 (unify hv rv env1)]
                   (let [bound-vars (set (keys env2))
                         ordered-body (reorder-clauses body bound-vars)]
                     (reduce (fn [envs body-clause]
                               (mapcat #(solve-clause body-clause rules db % visited')
                                       envs))
                             [env2] ordered-body))
                   [])
                 [])))
           matching))))))

;; ── graph algorithms helpers (P2, P3, P4) ────────────────────────────────────

(defn shortest-path-bfs
  "Find all shortest paths from starting node in graph."
  [db from edge max-depth]
  (loop [q (conj clojure.lang.PersistentQueue/EMPTY [from [from]])
         visited #{from}
         paths {}]
    (if (empty? q)
      paths
      (let [[curr path] (peek q)
            depth (dec (count path))
            q' (pop q)]
        (if (and max-depth (>= depth max-depth))
          (recur q' visited paths)
          (let [neighbors (get-in db [:eav curr edge] #{})
                unvisited-neighbors (clojure.set/difference neighbors visited)
                new-paths (reduce (fn [acc n] (assoc acc n (conj path n))) {} unvisited-neighbors)
                next-q (reduce (fn [acc n] (conj acc [n (conj path n)])) q' unvisited-neighbors)
                next-visited (clojure.set/union visited unvisited-neighbors)]
            (recur next-q next-visited (merge paths new-paths))))))))

(defn solve-shortest-path [clause rules db env visited-rules]
  ;; (shortest-path ?from ?to ?edge ?path-var ?cost-var ?max-depth)
  (if (< (count clause) 4)
    []
    (let [from (nth clause 1)
          to (nth clause 2)
          edge (nth clause 3)
          path-var (when (>= (count clause) 5) (nth clause 4))
          cost-var (when (>= (count clause) 6) (nth clause 5))
          max-depth (when (>= (count clause) 7) (nth clause 6))
          from-val (resolve-term from env)
          edge-val (resolve-term edge env)]
    (if (variable? from-val)
      [] ;; starting node must be bound
      (let [max-d (when max-depth (resolve-term max-depth env))
            paths (shortest-path-bfs db from-val edge-val max-d)
            all-paths (assoc paths from-val [from-val])
            to-val (resolve-term to env)]
        (if (not (variable? to-val))
          (if-let [path (get all-paths to-val)]
            (let [cost (dec (count path))]
              (cond-> [env]
                (variable? path-var) (->> (mapcat #(if-let [e (unify path-var path %)] [e] [])))
                (variable? cost-var) (->> (mapcat #(if-let [e (unify cost-var cost %)] [e] [])))))
            [])
          (mapcat (fn [[target path]]
                    (let [cost (dec (count path))]
                      (if-let [env1 (unify to target env)]
                        (cond-> [env1]
                          (variable? path-var) (->> (mapcat #(if-let [e (unify path-var path %)] [e] [])))
                          (variable? cost-var) (->> (mapcat #(if-let [e (unify cost-var cost %)] [e] [])))
                          true                 identity)
                        [])))
                  all-paths)))))))

;; ── vector similarity math (P2) ──────────────────────────────────────────────

(defn cosine-similarity [a b]
  (if-not (= (count a) (count b))
    nil
    (let [dot-product (reduce + (map * a b))
          mag-a (Math/sqrt (reduce + (map #(* % %) a)))
          mag-b (Math/sqrt (reduce + (map #(* % %) b)))]
      (if (or (zero? mag-a) (zero? mag-b))
        nil
        (/ dot-product (* mag-a mag-b))))))

;; ── query cache (P2) ─────────────────────────────────────────────────────────

(defonce query-cache (atom {}))
(def max-cache-size 100)

(defn get-cached-query [cache-key]
  (when-let [entry (get @query-cache cache-key)]
    (swap! query-cache assoc-in [cache-key :last-accessed] (System/currentTimeMillis))
    (:val entry)))

(defn cache-query! [cache-key val]
  (swap! query-cache assoc cache-key {:val val :last-accessed (System/currentTimeMillis)})
  (when (> (count @query-cache) max-cache-size)
    (let [oldest (apply min-key (fn [[_ entry]] (:last-accessed entry)) @query-cache)]
      (swap! query-cache dissoc (first oldest)))))

(defn build-graph [db edge]
  (get-in db [:aev edge] {}))

(defn solve-reachable [clause rules db env visited-rules]
  (if (< (count clause) 4)
    []
    (let [[_ from edge node-var] clause
          from-val (resolve-term from env)
          edge-val (resolve-term edge env)]
    (if (variable? from-val)
      []
      (let [paths (shortest-path-bfs db from-val edge-val nil)
            reachable-nodes (conj (keys paths) from-val)
            node-val (resolve-term node-var env)]
        (if (not (variable? node-val))
          (if (contains? (set reachable-nodes) node-val)
            [env]
            [])
          (mapcat #(if-let [e (unify node-var % env)] [e] []) reachable-nodes)))))))

(defn- cd-dfs [graph node visited in-stack stack cycles-ref]
  (let [visited (conj visited node)
        in-stack (conj in-stack node)
        stack (conj stack node)
        neighbors (get graph node #{})]
    (let [[next-visited next-in-stack]
          (reduce (fn [[v is] neighbor]
                    (cond
                      (contains? is neighbor)
                      (do
                        (let [idx (.indexOf stack neighbor)
                              cycle (if (neg? idx) [neighbor] (subvec stack idx))]
                          (swap! cycles-ref conj cycle))
                        [v is])
                      
                      (contains? v neighbor)
                      [v is]
                      
                      :else
                      (let [[v' is'] (cd-dfs graph neighbor v is stack cycles-ref)]
                        [v' is'])))
                  [visited in-stack]
                  neighbors)]
      [next-visited (disj next-in-stack node)])))

(defn cycle-detect [db edge]
  (let [graph (build-graph db edge)
        all-nodes (set (concat (keys graph) (mapcat graph (keys graph))))
        cycles (atom #{})
        _ (reduce (fn [visited node]
                    (if (contains? visited node)
                      visited
                      (first (cd-dfs graph node visited #{} [] cycles))))
                  #{}
                  all-nodes)]
    (vec @cycles)))

(defn solve-cycle-detect [clause rules db env visited-rules]
  (if (< (count clause) 3)
    []
    (let [[_ edge cycle-var] clause
          edge-val (resolve-term edge env)
          cycles (cycle-detect db edge-val)
          cycle-val (resolve-term cycle-var env)]
    (if (not (variable? cycle-val))
      (if (contains? (set cycles) cycle-val)
        [env]
        [])
      (mapcat #(if-let [e (unify cycle-var % env)] [e] []) cycles)))))

(defn topological-sort [db edge]
  (let [graph (build-graph db edge)
        all-nodes (set (concat (keys graph) (mapcat graph (keys graph))))
        in-degree (reduce (fn [acc node]
                            (let [neighbors (get graph node #{})]
                              (reduce (fn [m n] (update m n (fnil inc 0))) acc neighbors)))
                          (zipmap all-nodes (repeat 0))
                          all-nodes)
        zero-in (filter #(zero? (get in-degree %)) all-nodes)]
    (loop [q (into clojure.lang.PersistentQueue/EMPTY zero-in)
           in-deg in-degree
           order []]
      (if (empty? q)
        (if (= (count order) (count all-nodes))
          {:ok order}
          {:error (filter #(pos? (get in-deg %)) all-nodes)})
        (let [curr (peek q)
              q' (pop q)
              neighbors (get graph curr #{})
              [next-q next-in-deg]
              (reduce (fn [[q-acc id-acc] neighbor]
                        (let [new-deg (dec (get id-acc neighbor))]
                          [(if (zero? new-deg) (conj q-acc neighbor) q-acc)
                           (assoc id-acc neighbor new-deg)]))
                      [q' in-deg]
                      neighbors)]
          (recur next-q next-in-deg (conj order curr)))))))

(defn solve-topological-sort [clause rules db env visited-rules]
  (if (< (count clause) 3)
    []
    (let [[_ edge order-var] clause
          edge-val (resolve-term edge env)
          res (topological-sort db edge-val)]
    (if-let [order (:ok res)]
      (let [order-val (resolve-term order-var env)]
        (if (not (variable? order-val))
          (if (= order-val order) [env] [])
          (if-let [e (unify order-var order env)] [e] [])))
      []))))

(defn- preprocess-pagerank [graph all-nodes]
  (let [out-degrees (into {} (map (fn [[s ts]] [s (count ts)]) graph))
        incoming (reduce (fn [acc [source targets]]
                           (reduce (fn [m target]
                                     (update m target (fnil conj []) source))
                                   acc
                                   targets))
                         {}
                         graph)]
    [incoming out-degrees]))

(defn pagerank [db edge damping iterations]
  (let [graph (build-graph db edge)
        all-nodes (set (concat (keys graph) (mapcat graph (keys graph))))
        n (double (count all-nodes))]
    (if (zero? n)
      {}
      (let [[incoming out-degrees] (preprocess-pagerank graph all-nodes)
            initial-ranks (zipmap all-nodes (repeat (/ 1.0 n)))]
        (loop [ranks initial-ranks
               iter iterations]
          (if (zero? iter)
            ranks
            (let [next-ranks
                  (into {}
                        (map (fn [u]
                               (let [incoming-nodes (get incoming u [])
                                     sum-val (reduce (fn [s v]
                                                       (let [rank-v (get ranks v 0.0)
                                                             deg-v (get out-degrees v 1)]
                                                         (+ s (/ rank-v (double deg-v)))))
                                                     0.0
                                                     incoming-nodes)
                                     new-rank (+ (/ (- 1.0 damping) n) (* damping sum-val))]
                                 [u new-rank]))
                             all-nodes))]
              (recur next-ranks (dec iter)))))))))

(defn solve-pagerank [clause rules db env visited-rules]
  (if (< (count clause) 6)
    []
    (let [[_ entity-var edge rank-var damping-p iterations-p] clause
          edge-val (resolve-term edge env)
        damping-val (double (resolve-term damping-p env))
        iter-val (int (resolve-term iterations-p env))
        ranks (pagerank db edge-val damping-val iter-val)
        entity-val (resolve-term entity-var env)
        rank-val (resolve-term rank-var env)]
    (if (not (variable? entity-val))
      (if-let [score (get ranks entity-val)]
        (if (not (variable? rank-val))
          (if (== rank-val score) [env] [])
          (if-let [e (unify rank-var score env)] [e] []))
        [])
      (mapcat (fn [[ent score]]
                (if-let [env1 (unify entity-var ent env)]
                  (if (not (variable? rank-val))
                    (if (== rank-val score) [env1] [])
                    (if-let [e (unify rank-var score env1)] [e] []))
                  []))
              ranks)))))

(defn strongly-connected-components [db edge]
  (let [graph (build-graph db edge)
        all-nodes (set (concat (keys graph) (mapcat graph (keys graph))))
        index (atom 0)
        indices (atom {})
        lowlinks (atom {})
        on-stack (atom #{})
        stack (atom [])
        components (atom {})
        comp-id (atom 0)]
    (letfn [(dfs [v]
              (let [idx @index]
                (swap! index inc)
                (swap! indices assoc v idx)
                (swap! lowlinks assoc v idx)
                (swap! on-stack conj v)
                (swap! stack conj v))
              (doseq [w (get graph v #{})]
                (cond
                  (not (contains? @indices w))
                  (do
                    (dfs w)
                    (swap! lowlinks assoc v (min (get @lowlinks v) (get @lowlinks w))))
                  
                  (contains? @on-stack w)
                  (swap! lowlinks assoc v (min (get @lowlinks v) (get @indices w)))))
              (when (= (get @lowlinks v) (get @indices v))
                (loop [comp-nodes []]
                  (let [top (last @stack)]
                    (swap! stack pop)
                    (swap! on-stack disj top)
                    (swap! components assoc top @comp-id)
                    (if (= top v)
                      (swap! comp-id inc)
                      (recur (conj comp-nodes top)))))))]
      (doseq [node all-nodes]
        (when-not (contains? @indices node)
          (dfs node)))
      @components)))

(defn solve-scc [clause rules db env visited-rules]
  (if (< (count clause) 4)
    []
    (let [[_ edge entity-var component-var] clause
          edge-val (resolve-term edge env)
        comps (strongly-connected-components db edge-val)
        entity-val (resolve-term entity-var env)
        comp-val (resolve-term component-var env)]
    (if (not (variable? entity-val))
      (if-let [cid (get comps entity-val)]
        (if (not (variable? comp-val))
          (if (= comp-val cid) [env] [])
          (if-let [e (unify component-var cid env)] [e] []))
        [])
      (mapcat (fn [[ent cid]]
                (if-let [env1 (unify entity-var ent env)]
                  (if (not (variable? comp-val))
                    (if (= comp-val cid) [env1] [])
                    (if-let [e (unify component-var cid env1)] [e] []))
                  []))
              comps)))))

(defn- bloom-hashes [key size hash-count]
  (map (fn [i]
         (let [h (hash [key i])]
           (mod (Math/abs h) size)))
       (range 1 (inc hash-count))))

(defn bloom-create [size hash-count]
  {:size size
   :hash-count hash-count
   :bits #{}})

(defn bloom-insert [filter key]
  (let [hashes (bloom-hashes key (:size filter) (:hash-count filter))]
    (update filter :bits clojure.set/union (set hashes))))

(defn bloom-might-contain? [filter key]
  (let [hashes (bloom-hashes key (:size filter) (:hash-count filter))]
    (clojure.set/subset? (set hashes) (:bits filter))))

(defn solve-clause
  "Dispatch a clause — negative, filter, shortest-path, graph algos, rules, or indexed patterns."
  [clause rules db env visited]
  (cond
    (negative-clause? clause)
    (solve-negative (extract-negative-inner clause) rules db env visited)

    (filter-clause? clause)
    (if (eval-filter clause env) [env] [])

    ;; ShortestPath
    (and (seq? clause) (= (first clause) 'shortest-path))
    (solve-shortest-path clause rules db env visited)

    ;; Reachable
    (and (seq? clause) (= (first clause) 'reachable))
    (solve-reachable clause rules db env visited)

    ;; CycleDetect
    (and (seq? clause) (= (first clause) 'cycle-detect))
    (solve-cycle-detect clause rules db env visited)

    ;; TopologicalSort
    (and (seq? clause) (= (first clause) 'topological-sort))
    (solve-topological-sort clause rules db env visited)

    ;; PageRank
    (and (seq? clause) (= (first clause) 'pagerank))
    (solve-pagerank clause rules db env visited)

    ;; SCC (strongly connected components)
    (and (seq? clause) (= (first clause) 'scc))
    (solve-scc clause rules db env visited)

    (seq? clause)
    (solve-rule clause rules db env visited)

    :else
    (match-fact clause db env)))

;; ── aggregate functions (P1) ─────────────────────────────────────────────────

(defn aggregate-values
  "Compute aggregate function value over a list of values."
  [op values]
  (case op
    count (count values)
    sum   (reduce + 0 (filter number? values))
    min   (if (empty? values) nil (first (sort values)))
    max   (if (empty? values) nil (last (sort values)))
    avg   (if (empty? values) 0.0 (/ (double (reduce + 0 (filter number? values))) (count values)))
    median (if (empty? values)
             nil
             (let [sorted (sort values)
                   cnt (count sorted)
                   mid (quot cnt 2)]
               (if (odd? cnt)
                 (nth sorted mid)
                 (let [v1 (nth sorted (dec mid))
                       v2 (nth sorted mid)]
                   (if (and (number? v1) (number? v2))
                     (/ (+ v1 v2) 2.0)
                     v1)))))
    nil))

;; ── scoring & weighted union (P1) ────────────────────────────────────────────

(defn normalize-scores
  "Normalize scores of results based on strategy (:min-max or :none)."
  [results strategy]
  (case strategy
    :min-max
    (if (empty? results)
      []
      (let [scores (map :score results)
            min-s (apply min scores)
            max-s (apply max scores)
            range-s (- max-s min-s)
            safe-range (if (zero? range-s) 1.0 range-s)]
        (map (fn [r]
               (assoc r :score (/ (- (:score r) min-s) safe-range)))
             results)))
    results))

(defn weighted-union
  "Combine two lists of scored results [{:entity e :score s}] by weighted union."
  [results-a results-b weight-a weight-b normalization]
  (let [norm-a (normalize-scores results-a normalization)
        norm-b (normalize-scores results-b normalization)
        map-a (into {} (map (juxt :entity :score) norm-a))
        map-b (into {} (map (juxt :entity :score) norm-b))
        all-entities (distinct (concat (keys map-a) (keys map-b)))]
    (->> all-entities
         (map (fn [e]
                (let [score-a (get map-a e 0.0)
                      score-b (get map-b e 0.0)
                      final-score (+ (* weight-a score-a) (* weight-b score-b))]
                  {:entity e :score final-score})))
         (sort-by :score >)
         vec)))

(defn do-query-datalog
  [q-map db rules inputs-map]
  (let [initial-env inputs-map
        bound-vars (set (keys inputs-map))
        ordered-clauses (reorder-clauses (:where q-map) bound-vars)
        envs (reduce (fn [envs clause]
                       (mapcat #(solve-clause clause rules db % #{})
                               envs))
                     [initial-env]
                     ordered-clauses)
        find-exprs (:find q-map)
        has-aggregates? (some seq? find-exprs)]
    (if-not has-aggregates?
      (mapv (fn [env] (mapv #(resolve-term % env) find-exprs))
            (distinct envs))
      (let [group-keys (filterv #(not (seq? %)) find-exprs)
            grouped (group-by (fn [env]
                                (mapv #(resolve-term % env) group-keys))
                              (distinct envs))
            projected (mapv (fn [[group-vals group-envs]]
                              (let [val-map (zipmap group-keys group-vals)]
                                (mapv (fn [expr]
                                        (if (seq? expr)
                                          (let [op (first expr)
                                                var (second expr)
                                                vals (map #(resolve-term var %) group-envs)]
                                            (aggregate-values op vals))
                                          (get val-map expr)))
                                      find-exprs)))
                            grouped)]
        projected))))

(defn query-datalog
  "Top-level query driver. Threads the initial environment through each
   where-clause sequentially, collecting all valid binding environments,
   then projects the :find variables. Uses query-cache."
  [q-map db rules inputs-map]
  (let [cache-key [q-map (:facts db) rules inputs-map]]
    (if-let [cached (get-cached-query cache-key)]
      cached
      (let [res (do-query-datalog q-map db rules inputs-map)]
        (cache-query! cache-key res)
        res))))

;; ── datom ingestion & rule compilation ───────────────────────────────────────

(defn- extract-rule-from-entity-datoms [entity-datoms rule-attrs]
  (let [find-val (fn [attr] (:value (first (filter #(= (:attribute %) attr) entity-datoms))))
        head-0 (find-val "rule/head_0")
        head-1 (find-val "rule/head_1")
        head-2 (find-val "rule/head_2")
        head-expr (when (and head-1 head-0)
                    (list (rule-name-for head-1)
                          (clean-symbol head-0)
                          (if head-2 (clean-symbol head-2) '_)))

        clauses (loop [idx 0 acc []]
                  (let [e-attr (str "rule/body_" idx "_0")
                        a-attr (str "rule/body_" idx "_1")
                        v-attr (str "rule/body_" idx "_2")]
                    (if (some #(= (:attribute %) e-attr) entity-datoms)
                      (let [clause [(find-val e-attr) (find-val a-attr) (find-val v-attr)]]
                        (recur (inc idx) (conj acc clause)))
                      acc)))
        compiled-clauses (keep (fn [[e a v]]
                                 (when (and e a)
                                   (if (and (string? a) (clojure.string/starts-with? a "?"))
                                     [(clean-symbol e) (clean-symbol a) (if v (clean-symbol v) '_)]
                                     (if (and rule-attrs (contains? rule-attrs a))
                                       (list (rule-name-for a) (clean-symbol e) (if v (clean-symbol v) '_))
                                       [(clean-symbol e) (keyword a) (if v (clean-symbol v) '_)]))))
                               clauses)]
    (if head-expr
      (vec (cons head-expr compiled-clauses))
      (vec compiled-clauses))))

(defn init-datascript
  "Initialize the indexed database from raw datom payloads.
   Separates rule-datoms from fact-datoms, compiles rules, builds indexes."
  [datoms]
  (let [is-rule? (fn [d] (clojure.string/starts-with? (:attribute d) "rule/"))
        rule-datoms (filter is-rule? datoms)
        fact-datoms (filter #(not (is-rule? %)) datoms)

        grouped-rules (group-by :entity rule-datoms)
        rule-attrs (set (keep (fn [[_ ds]]
                                (some #(when (= (:attribute %) "rule/head_1") (:value %)) ds))
                              grouped-rules))
        compiled-rules (mapv (fn [[_ ds]] (extract-rule-from-entity-datoms ds rule-attrs))
                             grouped-rules)

        entities (set (map :entity datoms))
        ref-values (set (keep (fn [d] (when (contains? entities (:value d)) (:value d))) fact-datoms))
        all-nodes (set/union entities ref-values)
        name-facts (mapv (fn [n] [n :name n]) all-nodes)

        base-facts (mapv (fn [d]
                           [(:entity d) (keyword (:attribute d)) (:value d)])
                         fact-datoms)
        all-facts (vec (concat name-facts base-facts))
        indexes (build-indexes all-facts)]
    {:facts   (atom all-facts)
     :indexes (atom indexes)
     :rules   compiled-rules}))

(defn resolve-query-input [facts v]
  (if (string? v)
    (if-let [name-fact (first (filter (fn [[e a v2]] (and (= a :name) (= v2 v))) facts))]
      (first name-fact)
      v)
    v))

(defn resolve-entity-names [facts results]
  (let [name-map (into {} (keep (fn [[e a v]] (when (= a :name) [e v])) facts))
        resolve-val (fn [v] (if (integer? v) (get name-map v v) v))]
    (walk/postwalk resolve-val results)))

(defn- executable-in-path? [cmd]
  (let [words (clojure.string/split cmd #"\s+")
        clean-words (filter #(not (clojure.string/includes? % "=")) words)
        first-word (first clean-words)]
    (if (nil? first-word)
      false
      (let [built-ins #{"cd" "echo" "exit" "source" "export" "set" "alias"}
            lower-word (clojure.string/lower-case first-word)]
        (if (contains? built-ins lower-word)
          true
          (let [f (io/file first-word)]
            (if (and (.exists f) (not (.isDirectory f)) (.canExecute f))
              true
              (let [path-env (System/getenv "PATH")
                    paths (if (nil? path-env) [] (clojure.string/split path-env (re-pattern java.io.File/pathSeparator)))
                    os-name (clojure.string/lower-case (System/getProperty "os.name"))
                    is-windows? (clojure.string/includes? os-name "win")
                    extensions (if is-windows? ["" ".exe" ".bat" ".cmd"] [""])]
                (boolean
                 (some (fn [dir]
                         (some (fn [ext]
                                 (let [bin-file (io/file dir (str first-word ext))]
                                   (and (.exists bin-file) (not (.isDirectory bin-file)) (or is-windows? (.canExecute bin-file)))))
                               extensions))
                        paths))))))))))

(defn- shell-first-word [cmd]
  (or (first (filter #(not (clojure.string/includes? % "="))
                     (clojure.string/split (or cmd "") #"\s+")))
      "command"))

(defn- shell-policy-violation [cmd]
  (let [first-word (shell-first-word cmd)
        allowlist (env-list "HERMES_WORKER_SHELL_ALLOWLIST")]
    (cond
      (re-find #"(?i)\bpython(?:3)?\b" (or cmd ""))
      "Python invocation blocked; use Babashka (bb) instead."

      (and (seq allowlist) (not (contains? allowlist first-word)))
      (str "Executable '" first-word "' is not in HERMES_WORKER_SHELL_ALLOWLIST.")

      :else nil)))

(defn- format-command-result [{:keys [out err exit]}]
  (str "STDOUT:\n" out "\nSTDERR:\n" err "\nEXIT:" exit))

(defn- run-shell-command [cmd]
  (if-let [violation (shell-policy-violation cmd)]
    (do
      (log-event "warn" "shell_policy_block" {:command cmd :reason violation})
      (str "STDOUT:\n[BLOCKED] " violation "\nSTDERR:\n\nEXIT:126"))
    (if-not (executable-in-path? cmd)
      (let [bin-name (shell-first-word cmd)]
        (log-event "warn" "shell_executable_missing" {:command cmd :executable bin-name})
        (str "STDOUT:\n[WARN] Executable '" bin-name "' not found in PATH. Execution bypassed.\nSTDERR:\n\nEXIT:0"))
      (format-command-result (p/sh "sh" "-c" cmd)))))

(defn parse-robust-json [s]
  (try
    (json/parse-string s true)
    (catch Exception _
      (try
        (let [cleaned (clojure.string/replace s #"(?:\"|')?(inputs|facts)(?:\"|')?\s*:\s*(\[[\s\S]*\])"
                                              (fn [[_ key-val inputs-val]]
                                                (str "\"" key-val "\": " (clojure.string/replace inputs-val #"[\\\\\"]+" "\""))))
              edn-str (-> cleaned
                          (clojure.string/replace #"(?:\"|')?(command|path|content|url|code|image|query|inputs|facts)(?:\"|')?\s*:" ":$1")
                          (clojure.string/replace #",\s*" " "))
              edn-val (edn/read-string edn-str)]
          (walk/keywordize-keys edn-val))
        (catch Exception e
          (throw (Exception. (str "JSON/EDN parsing failed: " (.getMessage e) " for string: " s))))))))


;; ─── Tool Execution ───────────────────────────────────────────────────────────

(defn execute-tool [channel name args-str ds-db]
  (send-telemetry channel (str "tool_start:" name " args: " args-str))
  (try
    (let [args (parse-robust-json args-str)
          result (case name
                    "run_command"
                    (let [cmd (:command args)]
                      (when-let [violation (shell-policy-violation cmd)]
                        (send-telemetry channel (str "[POLICY] " violation)))
                      (run-shell-command cmd))

                   "read_file" (slurp (:path args))

                   "write_file" (do (spit (:path args) (:content args)) "File written successfully.")

                   "fetch_url" (:body (http/get (:url args)))

                   "bb_eval"
                   (let [code (:code args)
                         sw (java.io.StringWriter.)
                         se (java.io.StringWriter.)]
                     (try
                       (create-ns 'sandbox-user)
                       (binding [*ns* (find-ns 'sandbox-user)]
                         (refer 'clojure.core))
                       (let [eval-res (binding [*out* sw
                                                *err* se
                                                *ns* (find-ns 'sandbox-user)]
                                        (load-string code))]
                         (str "STDOUT:\n" (str sw)
                              "\nSTDERR:\n" (str se)
                              "\nRESULT:\n" (pr-str eval-res)
                              "\nEXIT:0"))
                       (catch Exception e
                         (str "STDOUT:\n" (str sw)
                              "\nSTDERR:\n" (str se)
                              "\nERROR:\n" (.getMessage e)
                              "\nEXIT:1"))))

                    "get_repl_state"
                    (try
                      (let [ns (find-ns 'sandbox-user)
                            interns (if ns (ns-interns ns) {})
                            var-names (keys interns)]
                        (json/generate-string {:vars (map str var-names)}))
                      (catch Exception e
                        (str "ERROR:\n" (.getMessage e))))

                   "run_in_docker"
                   (let [code (:code args)
                         image (or (:image args) "babashka/babashka:latest")
                         tmp-file (java.io.File/createTempFile "docker-bb-" ".clj")
                         _ (spit tmp-file code)]
                     (try
                       (if (docker-available?)
                         (let [cmd ["docker" "run" "--rm"
                                    "-v" (str (.getAbsolutePath tmp-file) ":/sandbox/script.clj:ro")
                                    image "bb" "/sandbox/script.clj"]
                               {:keys [out err exit]} (apply p/sh cmd)]
                           (str "STDOUT:\n" out "\nSTDERR:\n" err "\nEXIT:" exit))
                         (if (bb-available?)
                           (let [{:keys [out err exit]} (p/sh "bb" (.getAbsolutePath tmp-file))]
                             (str "[WARN: Docker unavailable — ran natively with bb]\nSTDOUT:\n" out "\nSTDERR:\n" err "\nEXIT:" exit))
                           "[ERROR: Neither Docker nor Babashka is available]"))
                       (finally (.delete tmp-file))))

                   "query_datalog"
                   (let [q-map (parse-query (:query args))
                         inputs (:inputs args)
                         in-vars (remove #{'$ '%} (:in q-map))
                         parsed-inputs (mapv #(if (and (string? %) (clojure.string/starts-with? % "?"))
                                                (symbol %)
                                                %)
                                             inputs)
                         facts @(:facts ds-db)
                         rules (:rules ds-db)
                         idx-db @(:indexes ds-db)
                         resolved-inputs (mapv #(resolve-query-input facts %) parsed-inputs)
                         inputs-map (zipmap in-vars resolved-inputs)
                         results (query-datalog q-map idx-db rules inputs-map)
                         resolved-results (resolve-entity-names facts results)]
                     (json/generate-string resolved-results))

                   "transact_datalog"
                   (let [new-facts (:facts args)
                         tx-data (mapv (fn [[e a v]] [(if (string? e) e e) (keyword a) v]) new-facts)]
                     (swap! (:facts ds-db) into tx-data)
                     ;; Rebuild indexes to include new facts
                     (reset! (:indexes ds-db) (build-indexes @(:facts ds-db)))
                     "Facts transacted successfully.")

                     "run_sandboxed_command"
                     (let [cmd (:command args)
                           custom-paths (or (:allowed_write_paths args) [])
                           os-name (clojure.string/lower-case (System/getProperty "os.name"))
                           is-mac? (clojure.string/includes? os-name "mac")]
                       (if-let [violation (shell-policy-violation cmd)]
                         (do
                           (send-telemetry channel (str "[POLICY] " violation))
                           (run-shell-command cmd))
                         (if is-mac?
                           (let [default-paths ["/tmp" "/private/tmp" "/var/folders" (System/getProperty "user.dir")]
                                 all-paths (distinct (concat default-paths custom-paths))
                                 write-rules (clojure.string/join " " (map #(str "(subpath \"" % "\")") all-paths))
                                 profile (str "(version 1) (deny default) (allow process-fork) (allow process-exec) (allow sysctl-read) (allow file-read*) (allow file-write* " write-rules ")")
                                 {:keys [out err exit]} (p/sh "sandbox-exec" "-p" profile "sh" "-c" cmd)]
                             (format-command-result {:out out :err err :exit exit}))
                           (str "[WARN: Not on macOS, running without sandboxing]\n" (run-shell-command cmd)))))

                   ;; Fallback to Gleam-delegated tool calls
                   (let [msg-id (rand-int 1000000)
                         req (json/generate-string {:jsonrpc "2.0"
                                                    :id msg-id
                                                    :method "call_tool_on_gleam"
                                                    :params {:name name :arguments args-str}})
                         _ (send-msg channel (str req "\n"))]
                     (recv-tool-response channel msg-id)))]
      (send-telemetry channel (str "tool_complete:" name))
      result)
    (catch Exception e
      (let [err (str "Error executing tool '" name "': " (.getName (class e)) ": " (.getMessage e))]
        (send-telemetry channel (str "tool_error:" name " - " err))
        err))))

(defn- post-json [url api-key body timeout-ms]
  (let [resp (http/post url
                        {:headers {"Authorization" (str "Bearer " api-key)
                                   "Content-Type" "application/json"}
                         :body (json/generate-string body)
                         :timeout timeout-ms
                         :throw false})]
    (if (>= (:status resp) 400)
      (throw (Exception. (str "HTTP error " (:status resp) ": " (:body resp))))
      resp)))

(defn handle-task [channel payload]
  (try
    (let [{:keys [url model api_key messages tools datoms]} payload
          ds-db (init-datascript datoms)
          merged-tools (if (seq tools) (merge-tool-schemas tools) tool-schemas)
          reasoning-prompt {:role "system" 
                            :content "You are an expert planner. Provide a step-by-step reasoning chain validating the user's request, outlining the necessary tool calls. Return ONLY the chain of thought."}
          reasoning-req-body {:model model
                              :messages (concat messages [reasoning-prompt])
                              :max_tokens 2048}
          _ (send-telemetry channel "status: reasoning_validation_started")
          reasoning-resp (with-retries* 2 1000
                           (fn []
                             (post-json url api_key reasoning-req-body 25000)))
          reasoning-result (json/parse-string (:body reasoning-resp) true)
          reasoning-msg (:message (first (:choices reasoning-result)))
          _ (send-telemetry channel (str "reasoning: \n" (:content reasoning-msg)))]
      
      (loop [loop-messages (vec (concat messages [reasoning-msg]))]
        (let [req-body {:model model
                        :messages loop-messages
                        :tools merged-tools
                        :max_tokens 4096}
              response (with-retries* 2 1000
                         (fn []
                           (post-json url api_key req-body 25000)))
              result (json/parse-string (:body response) true)
              choice (first (:choices result))
              msg (:message choice)]
          
          (if-let [tool-calls (:tool_calls msg)]
            (let [tool-results (map (fn [tc]
                                      (let [fn-name (-> tc :function :name)
                                            fn-args (-> tc :function :arguments)
                                            res (execute-tool channel fn-name fn-args ds-db)]
                                        {:role "tool"
                                         :tool_call_id (:id tc)
                                         :name fn-name
                                         :content res}))
                                    tool-calls)
                  next-messages (concat loop-messages [msg] tool-results)]
              (recur (vec next-messages)))
            
            (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                                     :method "task_result"
                                                     :params {:result result}}))))))
    (catch Exception e
      (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                               :error {:message (.getMessage e)}})))))

(defn read-loop [channel]
  (let [buf (ByteBuffer/allocate 65536)]
    (loop [acc ""]
      (if (clojure.string/includes? acc "\n")
        (let [lines (clojure.string/split acc #"\n")
              line (first lines)
              remaining (clojure.string/join "\n" (rest lines))]
          (when-not (clojure.string/blank? line)
            (try
              (let [msg (json/parse-string line true)]
                (when (= (:method msg) "execute_task")
                  (handle-task channel (:params msg))))
              (catch Exception e
                (println "Error parsing msg:" line))))
          (recur remaining))
        (do
          (.clear buf)
          (let [bytes-read (.read channel buf)]
            (if (pos? bytes-read)
              (do
                (.flip buf)
                (let [bytes (byte-array (.remaining buf))]
                  (.get buf bytes)
                  (recur (str acc (String. bytes "UTF-8")))))
              (when-not (= bytes-read -1)
                (recur acc)))))))))

(defn telemetry-loop [channel]
  (async/go-loop []
    (async/<! (async/timeout 5000))
    (let [ok (try
               (send-telemetry channel "running")
               true
               (catch Exception _ false))]
      (when ok (recur)))))

(defn parse-clause-helper [c all-rule-attrs]
  (let [c (walk/postwalk
           (fn [x]
             (cond
               (and (string? x) (contains? #{"not" "shortest-path" "reachable" "cycle-detect" "topological-sort" "pagerank" "scc" ">" "<" ">=" "<=" "=" "!=" "not=" "and" "or"} x))
               (symbol x)
               
               (and (string? x) (clojure.string/starts-with? x "?"))
               (symbol x)
               
               :else x))
           c)]
    (cond
      (or (and (seq? c) (= (first c) 'not))
          (and (vector? c) (= (first c) 'not)))
      (let [inner (second c)]
        (list 'not (parse-clause-helper inner all-rule-attrs)))

      (or (and (seq? c) (contains? #{'> '< '>= '<= '= '!= 'not= 'and 'or} (first c)))
          (and (vector? c)
               (or (seq? (first c)) (vector? (first c)))
               (contains? #{'> '< '>= '<= '= '!= 'not= 'and 'or} (first (first c)))))
      c

      (or (and (seq? c) (contains? #{'shortest-path 'reachable 'cycle-detect 'topological-sort 'pagerank 'scc} (first c)))
          (and (vector? c) (contains? #{'shortest-path 'reachable 'cycle-detect 'topological-sort 'pagerank 'scc} (first c))))
      (let [op (first c)
            edge-idx (case op
                       shortest-path 3
                       reachable 2
                       cycle-detect 1
                       topological-sort 1
                       pagerank 2
                       scc 1
                       nil)]
        (apply list
               (mapv (fn [[idx x]]
                       (cond
                         (and (symbol? x) (clojure.string/starts-with? (name x) "?"))
                         (clean-symbol (name x))

                         (and (string? x) (clojure.string/starts-with? x "?"))
                         (clean-symbol x)

                         (and (= idx edge-idx) (string? x))
                         (if (clojure.string/starts-with? x ":")
                           (keyword (subs x 1))
                           (keyword x))

                         (and (= idx edge-idx) (symbol? x))
                         (keyword (name x))

                         :else x))
                     (map-indexed vector c))))

      (< (count c) 2)
      c

      :else
      (let [attr (second c)
            has-val? (>= (count c) 3)
            parsed (cond-> [(first c)
                            (if (symbol? attr)
                              attr
                              (if (and (string? attr) (clojure.string/starts-with? attr "?"))
                                (clean-symbol attr)
                                (keyword attr)))]
                     has-val? (conj (clean-symbol (nth c 2))))]
        (if (contains? all-rule-attrs attr)
          (if has-val?
            (list (rule-name-for attr) (first parsed) (nth parsed 2))
            (list (rule-name-for attr) (first parsed) '_))
          parsed)))))

(defn handle-cli-query [payload]
  (let [datoms (:datoms payload)
        q (:query payload)
        db (init-datascript datoms)
        
        rules-raw (:rules payload)
        rule-attrs-payload (set (map second (map first (or rules-raw []))))
        rule-attrs-db (set (keep (fn [d] (when (= (:attribute d) "rule/head_1") (:value d))) datoms))
        all-rule-attrs (clojure.set/union rule-attrs-payload rule-attrs-db)
        
        parse-clause #(parse-clause-helper % all-rule-attrs)
        extra-rules (mapv (fn [r] (vec (cons (parse-clause (first r)) (mapv parse-clause (rest r))))) (or rules-raw []))
        
        all-rules (vec (concat (:rules db) extra-rules))
        facts @(:facts db)
        idx-db @(:indexes db)

        q-map {:find (mapv clean-symbol (:find q))
               :where (mapv parse-clause (:where q))}
        _ (binding [*out* *err*]
            (println "facts:" facts)
            (println "all-rules:" all-rules)
            (println "q-map:" q-map))

        results (query-datalog q-map idx-db all-rules {})
        resolved (resolve-entity-names facts results)
        find-vars (map str (:find q-map))
        mapped-results (map (fn [res-vec] (zipmap find-vars res-vec)) resolved)]
    (println (json/generate-string {:status "success" :results mapped-results}))))

(defn diagnose-uds-failure [path exception]
  (try
    (println "--- UDS Connection Diagnostics ---")
    (println "Target Path:" path)
    (let [file (java.io.File. path)
          parent (.getParentFile file)]
      (println "Socket file exists?:" (.exists file))
      (when (.exists file)
        (println "Is directory?:" (.isDirectory file))
        (println "Is readable?:" (.canRead file))
        (println "Is writable?:" (.canWrite file))
        (println "Length (bytes):" (.length file)))
      (println "Parent directory exists?:" (if parent (.exists parent) false))
      (when (and parent (.exists parent))
        (println "Parent path:" (.getAbsolutePath parent))
        (println "Parent is readable?:" (.canRead parent))
        (println "Parent is writable?:" (.canWrite parent)))
      (println "Exception type:" (.getName (class exception)))
      (println "Exception message:" (.getMessage exception))
      (println "----------------------------------"))
    (catch Exception e
      (println "Failed to run diagnostics:" (.getMessage e)))))

(defn health-status []
  (let [path (System/getenv "PATH")
        bb-ok (bb-available?)
        docker-ok (docker-available?)
        shell-allowlist (env-list "HERMES_WORKER_SHELL_ALLOWLIST")
        tool-timeout-ms (env-long "HERMES_WORKER_TOOL_TIMEOUT_MS" 30000)]
    {:status (if bb-ok "ok" "degraded")
     :checks {:babashka {:ok bb-ok
                         :message (if bb-ok "bb available" "bb not found in PATH; worker can run, but child bb fallbacks are disabled")}
              :docker {:ok docker-ok
                       :message (if docker-ok "docker available" "docker unavailable; run_in_docker will fall back to bb when possible")}
              :path {:ok (not (clojure.string/blank? path))
                     :message (if (clojure.string/blank? path) "PATH is empty" "PATH configured")}
              :delegated-tool-timeout-ms tool-timeout-ms
              :shell-allowlist (vec (or shell-allowlist []))}}))

(defn print-health [mode]
  (let [status (health-status)]
    (println (json/generate-string (assoc status :mode mode)))
    (= "ok" (:status status))))

(defn -main [& args]
  (let [cmd (first args)]
    (cond
      (contains? #{"--health" "health"} cmd)
      (System/exit (if (print-health "health") 0 1))

      (contains? #{"--doctor" "doctor"} cmd)
      (System/exit (if (print-health "doctor") 0 1))

      (= cmd "--datalog-query")
      (let [payload (json/parse-stream *in* true)]
        (handle-cli-query payload))
         
      :else
      (let [path cmd]
        (when (clojure.string/blank? path)
          (log-event "error" "worker_missing_uds_path" {:message "Usage: bb src/worker.clj <uds-path>|--health|--doctor|--datalog-query"})
          (System/exit 2))
        (log-event "info" "worker_started" {:uds_path path})
        (loop [attempt 1
               last-exception nil]
          (let [res (try
                       (let [channel (connect-uds path)]
                         (log-event "info" "uds_connected" {:uds_path path})
                         (send-msg channel "{\"jsonrpc\":\"2.0\",\"method\":\"init\",\"params\":{\"status\":\"ready\"}}")
                         (telemetry-loop channel)
                         (read-loop channel)
                         (log-event "warn" "uds_read_loop_exited" {:uds_path path})
                         {:ok true})
                       (catch Exception e
                         (log-event "warn" "uds_connection_failed" {:attempt attempt :max_attempts 3 :uds_path path :message (.getMessage e)})
                         {:error e}))]
            (if (:ok res)
              (recur 1 nil)
              (if (< attempt 3)
                (do
                  (log-event "info" "uds_autoheal_retry" {:delay_ms 1000 :next_attempt (inc attempt) :max_attempts 3})
                  (Thread/sleep 1000)
                  (recur (inc attempt) (:error res)))
                (do
                  (log-event "error" "uds_autoheal_exhausted" {:max_attempts 3 :uds_path path})
                  (diagnose-uds-failure path (:error res))
                  (System/exit 1))))))))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
