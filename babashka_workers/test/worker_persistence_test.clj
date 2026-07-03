(ns worker-persistence-test
  (:require
   [clojure.test :refer [deftest is testing run-tests]]
   [worker :as w]))

(deftest bb-eval-stateful-test
  (testing "Stateful execution captures defs and stdout/stderr"
    (with-redefs [w/send-telemetry (fn [_ _] nil)]
      ;; Define a function/var in the first run
      (let [args1 "{\"code\": \"(defn add-two [y] (+ y 2))\"}"
            res1 (w/execute-tool nil "bb_eval" args1 nil)]
        (is (clojure.string/includes? res1 "EXIT:0")))
      
      ;; Evaluate it in the second run to verify persistence
      (let [args2 "{\"code\": \"(add-two 10)\"}"
            res2 (w/execute-tool nil "bb_eval" args2 nil)]
        (is (clojure.string/includes? res2 "RESULT:\n12"))
        (is (clojure.string/includes? res2 "EXIT:0"))))))

(deftest bb-eval-stdout-stderr-test
  (testing "Capturing stdout and stderr"
    (with-redefs [w/send-telemetry (fn [_ _] nil)]
      (let [args "{\"code\": \"(binding [*out* *out*] (println \\\"hello world\\\"))\"}"
            res (w/execute-tool nil "bb_eval" args nil)]
        (is (clojure.string/includes? res "STDOUT:\nhello world"))))))

(deftest bb-eval-get-repl-state-test
  (testing "Retrieving REPL state (introspection)"
    (with-redefs [w/send-telemetry (fn [_ _] nil)]
      ;; Define a unique function
      (let [args1 "{\"code\": \"(defn multiply-by-three [y] (* y 3))\"}"
            _ (w/execute-tool nil "bb_eval" args1 nil)
            ;; Retrieve state
             state-res (w/execute-tool nil "get_repl_state" "{}" nil)]
         (is (clojure.string/includes? state-res "multiply-by-three"))))))

(deftest run-command-blocks-python-test
  (testing "Shell policy blocks Python invocations instead of rewriting them to success"
    (with-redefs [w/send-telemetry (fn [_ _] nil)]
      (let [res (w/execute-tool nil "run_command" "{\"command\":\"python3 -c 'print(1)'\"}" nil)]
        (is (clojure.string/includes? res "[BLOCKED] Python invocation blocked"))
        (is (clojure.string/includes? res "EXIT:126"))))))

(deftest run-command-allowlist-test
  (testing "Optional shell allowlist blocks non-listed executables"
    (with-redefs [w/send-telemetry (fn [_ _] nil)
                  #'w/env-list (fn [_] #{"echo"})]
      (let [res (w/execute-tool nil "run_command" "{\"command\":\"printf hi\"}" nil)]
        (is (clojure.string/includes? res "not in HERMES_WORKER_SHELL_ALLOWLIST"))
        (is (clojure.string/includes? res "EXIT:126"))))))

(deftest health-status-degraded-when-bb-missing-test
  (testing "Health check reports degraded instead of crashing when bb is missing"
    (with-redefs [w/bb-available? (fn [] false)
                  w/docker-available? (fn [] false)]
      (let [status (w/health-status)]
        (is (= "degraded" (:status status)))
        (is (false? (get-in status [:checks :babashka :ok])))
        (is (clojure.string/includes? (get-in status [:checks :babashka :message]) "bb not found"))))))

(defn -main [& args]
  (let [summary (run-tests 'worker-persistence-test)]
    (System/exit (if (pos? (+ (:fail summary) (:error summary))) 1 0))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
