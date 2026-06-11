(defn resolve-term [term env]
  (loop [t term seen #{}]
    (if (and (symbol? t) (clojure.string/starts-with? (name t) "?"))
      (if (seen t) t
          (if-let [bound (get env t)]
            (recur bound (conj seen t))
            t))
      t)))

(defn match-term? [pattern term env]
  (let [p (resolve-term pattern env)
        t (resolve-term term env)]
    (cond
      (and (symbol? p) (clojure.string/starts-with? (name p) "?"))
      (assoc env p t)
      
      (and (symbol? t) (clojure.string/starts-with? (name t) "?"))
      (assoc env t p)
      
      (= p t) env
      :else nil)))

(declare solve-clause)
(defn match-fact [clause facts env]
  (if (< (count clause) 2)
    [] ; invalid clause shape, return empty match
    (let [pe (first clause) 
          pa (second clause) 
          pv (if (>= (count clause) 3) (nth clause 2) '_)]
      (keep (fn [[e a v]]
              (when-let [env1 (match-term? pe e env)]
                (when-let [env2 (match-term? pa a env1)]
                  (if (= pv '_)
                    env2
                    (match-term? pv v env2)))))
            facts))))

(defn rename-vars [rule suffix]
  (clojure.walk/postwalk
   (fn [x]
     (if (and (symbol? x) (clojure.string/starts-with? (name x) "?"))
       (symbol (str (name x) "_" suffix))
       x))
   rule))

(def rule-counter (atom 0))

(defn solve-rule [clause rules facts env]
  (if (< (count clause) 3)
    []
    (let [rname (first clause)
          re (second clause)
          rv (nth clause 2)
          matching-rules (filter (fn [[head & _]] (and (= (first head) rname) (= (count head) 3))) rules)]
      (mapcat (fn [rule]
                (let [renamed-rule (rename-vars rule (swap! rule-counter inc))
                      [_ he hv] (first renamed-rule)
                      body (rest renamed-rule)]
                  (if-let [env1 (match-term? he re env)]
                    (if-let [env2 (match-term? hv rv env1)]
                      (reduce (fn [envs body-clause] (mapcat #(solve-clause body-clause rules facts %) envs)) [env2] body)
                      []) [])))
              matching-rules))))

(defn solve-clause [clause rules facts env]
  (if (seq? clause)
    (solve-rule clause rules facts env)
    (match-fact clause facts env)))

(defn query-datalog [q-map facts rules inputs-map]
  (let [initial-env inputs-map
        envs (reduce (fn [envs clause] (mapcat #(solve-clause clause rules facts %) envs)) [initial-env] (:where q-map))]
    (mapv (fn [env] (mapv #(resolve-term % env) (:find q-map))) (distinct envs))))

(def facts [["A" :route/link "B"] ["B" :route/link "C"] ["A" :session/active true] ["B" :session/active false]])
(def recursive-rules
  [[[(symbol "route-path") '?x '?y] ['?x :route/link '?y]]
   [[(symbol "route-path") '?x '?z] ['?x :route/link '?y] (list (symbol "route-path") '?y '?z)]])

(println "Recursive path query:" (query-datalog {:find ['?y] :where [(list (symbol "route-path") '?x '?y)]} facts recursive-rules {'?x "A"}))
(println "2-element clause query (all active session nodes):" (query-datalog {:find ['?s] :where [['?s :session/active]]} facts recursive-rules {}))
