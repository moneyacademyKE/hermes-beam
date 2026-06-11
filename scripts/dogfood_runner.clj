#!/usr/bin/env bb
(ns dogfood-runner
  (:require [babashka.process :as p]
            [clojure.java.io :as io]
            [clojure.string :as str]))

(def goals
  [{:id 1
    :name "Datalog Session Query"
    :prompt "/goal Query Datalog to find all active sessions in the database and print them."}
   {:id 2
    :name "HTTP & Filesystem"
    :prompt "/goal Write a clojure script that fetches 'https://httpbin.org/get' and writes the response headers to headers.txt."}
   {:id 3
    :name "Workspace Search"
    :prompt "/goal Find all files in the babashka_workers directory containing the word 'defn', print their names and line counts."}
   {:id 4
    :name "Bi-directional Datalog"
    :prompt "/goal Transact three new fact datoms into Datalog representing route links: A->B, B->C, C->D. Then query the path between A and D, and write the path result to path.txt."}
   {:id 5
    :name "OS Sandboxing"
    :prompt "/goal Evaluate a sandboxed shell command to run a small inline Clojure benchmark counting from 1 to 1,000,000 and print the execution time."}])

(defn run-goal [{:keys [id name prompt]}]
  (println "\n==================================================")
  (println "Starting Goal" id ":" name)
  (println "Prompt:" prompt)
  (println "==================================================")
  (let [proc (p/process {:out :inherit
                         :err :inherit
                         :in :pipe}
                        "./hermes" "repl")
        in (:in proc)]
    (try
      ;; Give it a second to boot up
      (Thread/sleep 3000)
      ;; Send the goal command
      (let [writer (io/writer in)]
        (.write writer (str prompt "\n"))
        (.flush writer))
      ;; Wait for the subagent worker to complete
      ;; We will sleep and check if the database or worker finished,
      ;; or monitor stdout. Since we inherited stdout/stderr, the output
      ;; will print directly to the console in real-time.
      ;; We will wait up to 45 seconds for each goal.
      (let [timeout-ms 55000
            start-time (System/currentTimeMillis)]
        (loop []
          (let [elapsed (- (System/currentTimeMillis) start-time)]
            (if (< elapsed timeout-ms)
              (do
                (Thread/sleep 2000)
                ;; We can check if any port exits or if telemetry finished
                (recur))
              (println "Time limit reached for goal" id)))))
      (finally
        (p/destroy proc)
        (println "Finished Goal" id)))))

(defn -main []
  (println "Starting Automated Dogfooding Suite on 5 Goals...")
  (doseq [g goals]
    (run-goal g))
  (println "\nAll 5 Dogfooding Goals completed execution."))

(-main)
