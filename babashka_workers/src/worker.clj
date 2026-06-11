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
               :description "Query the in-memory DataScript database using Clojure Datalog query syntax. Input: query-str (e.g. '[:find ?y :in $ % ?x :where (path ?x ?y)]'), inputs-list (e.g. '[\"A\"]')"
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
                            :required ["command"]}}}])

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
  (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                           :method "telemetry"
                                           :params {:status status
                                                    :memory (.freeMemory (Runtime/getRuntime))}})))

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

(defn recv-tool-response [channel expected-id]
  (let [buf (ByteBuffer/allocate 4096)]
    (loop [acc ""]
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
            (if (pos? bytes-read)
              (do
                (.flip buf)
                (let [bytes (byte-array (.remaining buf))]
                  (.get buf bytes)
                  (recur (str acc (String. bytes "UTF-8")))))
              (throw (Exception. "Socket closed while waiting for tool response")))))))))

(defn merge-tool-schemas [gleam-tools]
  (let [native-names (set (map #(get-in % [:function :name]) tool-schemas))
        filtered-gleam (filter #(not (contains? native-names (get-in % [:function :name])))
                               gleam-tools)]
    (vec (concat tool-schemas filtered-gleam))))

;; ─── Micro-Datalog Engine ────────────────────────────────────────────────────

(defn- clean-symbol [s]
  (if (and (string? s) (clojure.string/starts-with? s "?"))
    (symbol s)
    s))

(defn- rule-name-for [attr]
  (symbol (clojure.string/replace attr #"/" "-")))

(defn parse-query [query-str]
  (let [q (edn/read-string query-str)]
    (loop [rem q current-kw nil acc {:find [] :in [] :where []}]
      (if (empty? rem)
        acc
        (let [x (first rem)]
          (if (keyword? x)
            (recur (rest rem) x acc)
            (recur (rest rem) current-kw (if current-kw (update acc current-kw conj x) acc))))))))

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
  (let [pe (first clause) pa (second clause) pv (nth clause 2)]
    (keep (fn [[e a v]]
            (when-let [env1 (match-term? pe e env)]
              (when-let [env2 (match-term? pa a env1)]
                (match-term? pv v env2))))
          facts)))

(defn rename-vars [rule suffix]
  (clojure.walk/postwalk
   (fn [x]
     (if (and (symbol? x) (clojure.string/starts-with? (name x) "?"))
       (symbol (str (name x) "_" suffix))
       x))
   rule))

(def rule-counter (atom 0))

(declare solve-clause)

(defn solve-rule [clause rules facts env visited]
  (let [rname (first clause)
        re (second clause)
        rv (nth clause 2)
        evaluated-re (resolve-term re env)
        evaluated-rv (resolve-term rv env)
        goal [rname evaluated-re evaluated-rv]]
    (if (contains? visited goal)
      []
      (let [visited (conj visited goal)
            matching-rules (filter (fn [[head & _]] (and (= (first head) rname) (= (count head) 3))) rules)]
        (mapcat (fn [rule]
                  (let [renamed-rule (rename-vars rule (swap! rule-counter inc))
                        [_ he hv] (first renamed-rule)
                        body (rest renamed-rule)]
                    (if-let [env1 (match-term? he re env)]
                      (if-let [env2 (match-term? hv rv env1)]
                        (reduce (fn [envs body-clause] (mapcat #(solve-clause body-clause rules facts % visited) envs)) [env2] body)
                        []) [])))
                matching-rules)))))

(defn solve-clause [clause rules facts env visited]
  (if (seq? clause)
    (solve-rule clause rules facts env visited)
    (match-fact clause facts env)))

(defn query-datalog [q-map facts rules inputs-map]
  (let [initial-env inputs-map
        envs (reduce (fn [envs clause] (mapcat #(solve-clause clause rules facts % #{}) envs)) [initial-env] (:where q-map))]
    (mapv (fn [env] (mapv #(resolve-term % env) (:find q-map))) (distinct envs))))

(defn- extract-rule-from-entity-datoms [entity-datoms rule-attrs]
  (let [find-val (fn [attr] (:value (first (filter #(= (:attribute %) attr) entity-datoms))))
        head-0 (find-val "rule/head_0")
        head-1 (find-val "rule/head_1")
        head-2 (find-val "rule/head_2")
        head-expr (list (rule-name-for head-1) (clean-symbol head-0) (clean-symbol head-2))
        
        clauses (loop [idx 0 acc []]
                  (let [e-attr (str "rule/body_" idx "_0")
                        a-attr (str "rule/body_" idx "_1")
                        v-attr (str "rule/body_" idx "_2")]
                    (if (some #(= (:attribute %) e-attr) entity-datoms)
                      (let [clause [(find-val e-attr) (find-val a-attr) (find-val v-attr)]]
                        (recur (inc idx) (conj acc clause)))
                      acc)))
        compiled-clauses (mapv (fn [[e a v]]
                                 (if (and (string? a) (clojure.string/starts-with? a "?"))
                                   [(clean-symbol e) (clean-symbol a) (clean-symbol v)]
                                   (if (contains? rule-attrs a)
                                     (list (rule-name-for a) (clean-symbol e) (clean-symbol v))
                                     [(clean-symbol e) (keyword a) (clean-symbol v)])))
                               clauses)]
    (vec (cons head-expr compiled-clauses))))

(defn init-datascript [datoms]
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
                         fact-datoms)]
    {:facts (atom (vec (concat name-facts base-facts)))
     :rules compiled-rules}))

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

;; ─── Tool Execution ───────────────────────────────────────────────────────────

(defn execute-tool [channel name args-str ds-db]
  (send-telemetry channel (str "tool_start:" name " args: " args-str))
  (try
    (let [args (json/parse-string args-str true)
          result (case name
                   "run_command"
                   (let [cmd (:command args)
                         _ (when (re-find #"(?i)\bpython\b|\bpython3\b" cmd)
                             (send-telemetry channel "[POLICY] Python invocation blocked — use Babashka (bb) instead"))
                         safe-cmd (if (re-find #"(?i)\bpython\b|\bpython3\b" cmd)
                                    (str "echo '[BLOCKED: Python] Use Babashka instead: bb -e \"...\"'")
                                    cmd)
                         {:keys [out err exit]} (p/sh safe-cmd)]
                     (str "STDOUT:\n" out "\nSTDERR:\n" err "\nEXIT:" exit))

                   "read_file" (slurp (:path args))

                   "write_file" (do (spit (:path args) (:content args)) "File written successfully.")

                   "fetch_url" (:body (http/get (:url args)))

                   "bb_eval"
                   (let [tmp-file (java.io.File/createTempFile "bb-eval-" ".clj")
                         _ (spit tmp-file (:code args))
                         {:keys [out err exit]} (p/sh "bb" (.getAbsolutePath tmp-file))
                         _ (.delete tmp-file)]
                     (str "STDOUT:\n" out "\nSTDERR:\n" err "\nEXIT:" exit))

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
                         resolved-inputs (mapv #(resolve-query-input facts %) parsed-inputs)
                         inputs-map (zipmap in-vars resolved-inputs)
                         results (query-datalog q-map facts rules inputs-map)
                         resolved-results (resolve-entity-names facts results)]
                     (json/generate-string resolved-results))

                   "transact_datalog"
                   (let [new-facts (:facts args)
                         tx-data (mapv (fn [[e a v]] [(if (string? e) e e) (keyword a) v]) new-facts)]
                     (swap! (:facts ds-db) into tx-data)
                     "Facts transacted successfully.")

                    "run_sandboxed_command"
                    (let [cmd (:command args)
                          custom-paths (or (:allowed_write_paths args) [])
                          os-name (clojure.string/lower-case (System/getProperty "os.name"))
                          is-mac? (clojure.string/includes? os-name "mac")]
                      (if is-mac?
                        (let [default-paths ["/tmp" "/private/tmp" "/var/folders" "/Users/moe/Desktop/ayncoder"]
                              all-paths (distinct (concat default-paths custom-paths))
                              write-rules (clojure.string/join " " (map #(str "(subpath \"" % "\")") all-paths))
                              profile (str "(version 1) (deny default) (allow process-fork) (allow process-exec) (allow sysctl-read) (allow file-read*) (allow file-write* " write-rules ")")
                              {:keys [out err exit]} (p/sh "sandbox-exec" "-p" profile "sh" "-c" cmd)]
                          (str "STDOUT:\n" out "\nSTDERR:\n" err "\nEXIT:" exit))
                        (let [{:keys [out err exit]} (p/sh "sh" "-c" cmd)]
                          (str "[WARN: Not on macOS, running without sandboxing]\nSTDOUT:\n" out "\nSTDERR:\n" err "\nEXIT:" exit))))

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

(defn handle-task [channel payload]
  (try
    (let [{:keys [url model api_key messages tools datoms]} payload
          ds-db (init-datascript datoms)
          merged-tools (if (seq tools) (merge-tool-schemas tools) tool-schemas)
          reasoning-prompt {:role "system" 
                            :content "You are an expert planner. Provide a step-by-step reasoning chain validating the user's request, outlining the necessary tool calls. Return ONLY the chain of thought."}
          reasoning-req-body {:model model
                              :messages (concat messages [reasoning-prompt])}
          _ (send-telemetry channel "status: reasoning_validation_started")
          reasoning-resp (with-retries* 3 1000
                           (fn []
                             (http/post url
                                        {:headers {"Authorization" (str "Bearer " api_key)
                                                   "Content-Type" "application/json"}
                                         :body (json/generate-string reasoning-req-body)})))
          reasoning-result (json/parse-string (:body reasoning-resp) true)
          reasoning-msg (:message (first (:choices reasoning-result)))
          _ (send-telemetry channel (str "reasoning: \n" (:content reasoning-msg)))]
      
      (loop [loop-messages (vec (concat messages [reasoning-prompt reasoning-msg]))]
        (let [req-body {:model model
                        :messages loop-messages
                        :tools merged-tools}
              response (with-retries* 3 1000
                         (fn []
                           (http/post url
                                      {:headers {"Authorization" (str "Bearer " api_key)
                                                 "Content-Type" "application/json"}
                                       :body (json/generate-string req-body)})))
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

(defn handle-cli-query [payload]
  (let [datoms (:datoms payload)
        q (:query payload)
        db (init-datascript datoms)
        
        rules-raw (:rules payload)
        rule-attrs-payload (set (map second (map first (or rules-raw []))))
        rule-attrs-db (set (keep (fn [d] (when (= (:attribute d) "rule/head_1") (:value d))) datoms))
        all-rule-attrs (clojure.set/union rule-attrs-payload rule-attrs-db)
        
        parse-clause (fn [c] 
                       (let [attr (second c)
                             parsed [(clean-symbol (first c))
                                     (if (and (string? attr) (clojure.string/starts-with? attr "?"))
                                       (clean-symbol attr)
                                       (keyword attr))
                                     (clean-symbol (nth c 2))]]
                         (if (contains? all-rule-attrs attr)
                           (list (rule-name-for attr) (first parsed) (nth parsed 2))
                           parsed)))
        extra-rules (mapv (fn [r] (vec (cons (parse-clause (first r)) (mapv parse-clause (rest r))))) (or rules-raw []))
        
        all-rules (vec (concat (:rules db) extra-rules))
        facts @(:facts db)
        
        q-map {:find (mapv clean-symbol (:find q))
               :where (mapv parse-clause (:where q))}
        _ (println "facts:" facts)
        _ (println "all-rules:" all-rules)
        _ (println "q-map:" q-map)
               
        results (query-datalog q-map facts all-rules {})
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

(defn -main [& args]
  (let [cmd (first args)]
    (cond
      (= cmd "--datalog-query")
      (let [payload (json/parse-stream *in* true)]
        (handle-cli-query payload))
        
      :else
      (let [path cmd]
        (println "Worker started, targeting UDS path:" path)
        (loop [attempt 1
               last-exception nil]
          (let [res (try
                      (let [channel (connect-uds path)]
                        (println "Connected to UDS.")
                        (send-msg channel "{\"jsonrpc\":\"2.0\",\"method\":\"init\",\"params\":{\"status\":\"ready\"}}")
                        (telemetry-loop channel)
                        (read-loop channel)
                        (println "Read loop exited. Disconnected.")
                        {:ok true})
                      (catch Exception e
                        (println (str "Connection attempt " attempt "/3 failed targeting UDS: " (.getMessage e)))
                        {:error e}))]
            (if (:ok res)
              (recur 1 nil)
              (if (< attempt 3)
                (do
                  (println "Auto-healing UDS connection in 1s...")
                  (Thread/sleep 1000)
                  (recur (inc attempt) (:error res)))
                (do
                  (println "Error: UDS connection auto-healing exhausted. Maximum retries (3) reached. Exiting worker process.")
                  (diagnose-uds-failure path (:error res))
                  (System/exit 1))))))))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
