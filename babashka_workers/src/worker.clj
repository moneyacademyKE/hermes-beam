(ns worker
  (:require [clojure.core.async :as async]
            [cheshire.core :as json]
            [babashka.http-client :as http]
            [babashka.process :as p]
            [clojure.java.io :as io])
  (:import [java.net UnixDomainSocketAddress StandardProtocolFamily]
           [java.nio.channels SocketChannel]
           [java.nio ByteBuffer]))

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
                            :required ["image" "code"]}}}])

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

(defn execute-tool [channel name args-str]
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

                   ;; Inline Babashka evaluation
                   "bb_eval"
                   (let [tmp-file (java.io.File/createTempFile "bb-eval-" ".clj")
                         _ (spit tmp-file (:code args))
                         {:keys [out err exit]} (p/sh "bb" (.getAbsolutePath tmp-file))
                         _ (.delete tmp-file)]
                     (str "STDOUT:\n" out "\nSTDERR:\n" err "\nEXIT:" exit))

                   ;; Docker with Babashka image, native bb fallback
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

                   (str "Unknown tool: " name))]
      (send-telemetry channel (str "tool_complete:" name))
      result)
    (catch Exception e
      (let [err (str "Error executing tool '" name "': " (.getName (class e)) ": " (.getMessage e))]
        (send-telemetry channel (str "tool_error:" name " - " err))
        err))))

(defn handle-task [channel payload]
  (try
    (let [{:keys [url model api_key messages]} payload
          ;; Phase 1: Reasoning Validation
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
      
      ;; Phase 2: Execution Loop
      (loop [loop-messages (vec (concat messages [reasoning-prompt reasoning-msg]))]
        (let [req-body {:model model
                        :messages loop-messages
                        :tools tool-schemas}
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
            ;; Intercept tool calls, execute, and recurse
            (let [tool-results (map (fn [tc]
                                      (let [fn-name (-> tc :function :name)
                                            fn-args (-> tc :function :arguments)
                                            res (execute-tool channel fn-name fn-args)]
                                        {:role "tool"
                                         :tool_call_id (:id tc)
                                         :name fn-name
                                         :content res}))
                                    tool-calls)
                  next-messages (concat loop-messages [msg] tool-results)]
              (recur (vec next-messages)))
            
            ;; Finished
            (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                                     :method "task_result"
                                                     :params {:result result}}))))))
    (catch Exception e
      (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                               :error {:message (.getMessage e)}})))))

(defn read-loop [channel]
  (let [buf (ByteBuffer/allocate 65536)]
    (loop []
      (.clear buf)
      (let [bytes-read (.read channel buf)]
        (when (pos? bytes-read)
          (.flip buf)
          (let [bytes (byte-array (.remaining buf))
                _ (.get buf bytes)
                msg-str (String. bytes "UTF-8")]
            (try
              (let [msg (json/parse-string msg-str true)]
                (when (= (:method msg) "execute_task")
                  (handle-task channel (:params msg))))
              (catch Exception e
                (println "Error parsing msg:" msg-str)))))
        (when-not (= bytes-read -1)
          (recur))))))

(defn telemetry-loop [channel]
  (async/go-loop []
    (async/<! (async/timeout 5000))
    (let [ok (try
               (send-telemetry channel "running")
               true
               (catch Exception _ false))]
      (when ok (recur)))))

(defn -main [& args]
  (let [path (first args)]
    (println "Worker started, targeting UDS path:" path)
    (loop []
      (try
        (let [channel (connect-uds path)]
          (println "Connected to UDS.")
          (send-msg channel "{\"jsonrpc\":\"2.0\",\"method\":\"init\",\"params\":{\"status\":\"ready\"}}")
          (telemetry-loop channel)
          (read-loop channel)
          (println "Read loop exited. Disconnected."))
        (catch Exception e
          (println "Connection error:" (.getMessage e))))
      (println "Auto-healing UDS connection in 1s...")
      (Thread/sleep 1000)
      (recur))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
