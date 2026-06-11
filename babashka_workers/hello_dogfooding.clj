#!/usr/bin/env bb
(ns dogfood-runner
  (:require [babashka.process :as p]
            [clojure.java.io :as io]
            [clojure.string :as str]))

(def goals
  [{:id 9
    :name "Codebase Deprecation Audit"
    :prompt "/goal Find all python files in the directory using 'os.path' and write a script to migrate them to 'pathlib.Path'."}
   {:id 10
    :name "Typo and Docstring Inspector"
    :prompt "/goal Write a tool that scans the python files in the workspace for spelling errors in docstrings and fixes them."}
   {:id 11
    :name "Static Linting Checker"
    :prompt "/goal Execute a mock flake8 command over python files, parse the stdout result, and write a summary to lint_report.txt."}
   {:id 12
    :name "Config YAML Schema Validation"
    :prompt "/goal Parse the example YAML configuration file 'cli-config.yaml.example' and write a validation script to assert all required keys under 'display' exist."}
   {:id 13
    :name "Dynamic Port Allocation Inspector"
    :prompt "/goal Write a Clojure script that scans system ports, finds the first free port above 5000, and writes it to port.txt."}
   {:id 14
    :name "Subprocess Signal Handling Test"
    :prompt "/goal Spawn a subprocess running a sleep command, send it a SIGTERM signal after 2 seconds, and verify that it terminates cleanly, writing the exit status."}
   {:id 15
    :name "Git Branch and Commit Historian"
    :prompt "/goal Parse git log history for the last 5 commits and format the commit messages as a markdown table in changelog.md."}
   {:id 16
    :name "Environment Variable Overlay Simulator"
    :prompt "/goal Write a script that loads environment variables from a mock '.env' file, overlays them with system variables, and prints the resolved configuration."}
   {:id 17
    :name "File Compression and Archiver"
    :prompt "/goal Create a tarball containing all markdown files under the root directory and place it in the temp directory."}
   {:id 18
    :name "Relational Schema Migration Datalog Tool"
    :prompt "/goal Transact schema definitions representing database tables and columns into Datalog. Query for tables that lack a primary key, and print them."}
   {:id 19
    :name "Secure Shell Workspace Auditing"
    :prompt "/goal Execute a Seatbelt-restricted analysis of the workspace environment variables to verify that no secret keys are exposed in the system process variables."}
   {:id 20
    :name "HTTP Status Code Mock Service"
    :prompt "/goal Write an endpoint script that queries a list of HTTP urls, asserts that they return 200 OK, and writes URLs returning non-200 to errors.txt."}
   {:id 21
    :name "Git Diff and Patch Generator"
    :prompt "/goal Write a script that generates a unified git diff between the current git state and the HEAD commit, and saves it to patch.diff."}
   {:id 22
    :name "Markdown Link Checker"
    :prompt "/goal Scan all markdown files in the workspace for broken local file links (pointing to non-existent files) and print them."}
   {:id 23
    :name "CSV Data Aggregator and Reporter"
    :prompt "/goal Create a mock CSV dataset containing resource usages (CPU, Memory) per worker. Group the usage by worker and write a summary report."}
   {:id 24
    :name "JSON-RPC Schema Compliance Check"
    :prompt "/goal Parse a log of JSON-RPC telemetry messages, validate that they conform to the JSON-RPC 2.0 schema, and print the invalid envelopes."}
   {:id 25
    :name "Recursive File Grep Search"
    :prompt "/goal Implement a regex search scanner that finds all occurrences of import statements matching 'import ...' in 'babashka_workers' and writes them to imports.txt."}
   {:id 26
    :name "Subagent Diagnostics Log Audit"
    :prompt "/goal Scan agent.log or error logs for any socket connection failures and extract their diagnostics trace into a diagnostic_report.md."}
   {:id 27
    :name "Evolutionary Skill Deletion (Teardown)"
    :prompt "/goal Mutate the logical datalog registry by identifying obsolete skill entities and transacting a retraction to clean them up."}
   {:id 28
    :name "XML Parser and Struct Mapper"
    :prompt "/goal Write a script that parses an XML configuration string, maps it to a Clojure structure, and serializes it to JSON."}])

(defn run-goal [{:keys [id name prompt]}]
  (println "\n==================================================")
  (println "Starting Dogfood Goal" id ":" name)
  (println "Prompt:" prompt)
  (println "==================================================")
  (let [proc (p/process {:out :inherit
                         :err :inherit
                         :in :pipe}
                         "./hermes" "repl")
        in (:in proc)]
    (try
      (Thread/sleep 3000)
      (let [writer (io/writer in)]
        (.write writer (str prompt "\n"))
        (.flush writer))
      ;; Wait up to 35 seconds for each test goal to complete
      (let [timeout-ms 35000
            start-time (System/currentTimeMillis)]
        (loop []
          (let [elapsed (- (System/currentTimeMillis) start-time)]
            (if (< elapsed timeout-ms)
              (do
                (Thread/sleep 2000)
                (recur))
              (println "Time limit reached for goal" id)))))
      (finally
        (p/destroy proc)
        (println "Finished Goal" id)))))

(defn -main []
  (println (str "Starting DeepSWE Dogfooding Suite on " (count goals) " Goals..."))
  (doseq [g goals]
    (run-goal g))
  (println (str "\nDeepSWE Dogfooding Goals completed.")))

(-main)