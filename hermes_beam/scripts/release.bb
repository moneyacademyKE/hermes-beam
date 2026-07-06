#!/usr/bin/env bb
;; Hermes BEAM Release Script
;; Builds a self-contained escript from the Gleam project.
;; The escript requires only Erlang/OTP on the target machine (no Gleam needed).

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str]
         '[clojure.java.io :as io])

(def script-dir (fs/parent *file*))
(def project-root (fs/parent script-dir))
(def beam-dir (str project-root "/build/dev/erlang/hermes_beam/ebin"))
(def output-dir (str project-root "/build/release"))
(def escript-name "hermes_beam")

(defn step [msg]
  (println (str "\n\033[1;32m-> " msg "\033[0m")))

(defn check-tool [tool]
  (try
    (p/shell {:out :string} (str "which " tool))
    true
    (catch Exception _ false)))

(step "Checking prerequisites...")
(cond
  (not (check-tool "gleam"))
  (do (println "ERROR: gleam not found in PATH. Install from https://gleam.run/")
      (System/exit 1))
  (not (check-tool "erl"))
  (do (println "ERROR: erl not found in PATH. Install Erlang/OTP 26+.")
      (System/exit 1)))

(step "Building Gleam project...")
(let [result (p/shell {:dir project-root :out :string :err :string}
                    "gleam build")]
  (when (pos? (:exit result))
    (println "Build failed:")
    (println (:err result))
    (System/exit 1)))

(step "Verifying .beam files...")
(when-not (fs/exists? beam-dir)
  (println (str "ERROR: Build output not found at " beam-dir))
  (println "Expected compiled .beam files in ebin directory.")
  (System/exit 1))

(def beam-files
  (->> (fs/list-dir beam-dir)
       (filter #(str/ends-with? % ".beam"))
       (map fs/file-name)
       (sort)))

(println (str "Found " (count beam-files) " .beam files"))

(step "Creating escript archive...")
(fs/create-dirs output-dir)

(def escript-path (str output-dir "/" escript-name))

;; Build the escript using escript:create with an archive of all .beam files
;; We write an Erlang helper module to avoid quoting issues with -eval
(def erl-helper
  (str
   "-module(build_escript).\n"
   "-export([build/0]).\n"
   "\n"
   "build() ->\n"
   "    [OutputPath | _] = init:get_plain_arguments(),\n"
   "    EbinDir = \"" beam-dir "\",\n"
   "    {ok, AllBeams} = file:list_dir(EbinDir),\n"
   "    BeamFiles = [F || F <- AllBeams,\n"
   "                      filename:extension(F) =:= \".beam\",\n"
   "                      not lists:suffix(\"_test.beam\", F)],\n"
   "    io:format(\"Bundling ~p beam files~n\", [length(BeamFiles)]),\n"
   "    ArchiveEntries = lists:foldl(fun(F, Acc) ->\n"
   "        FullPath = filename:join(EbinDir, F),\n"
   "        case file:read_file(FullPath) of\n"
   "            {ok, Bin} -> [{F, Bin} | Acc];\n"
   "            _ -> Acc\n"
   "        end\n"
   "    end, [], BeamFiles),\n"
   "    %% Read bootstrap.beam if it exists\n"
   "    BootstrapPath = filename:join(EbinDir, \"bootstrap.beam\"),\n"
   "    FinalEntries = case file:read_file(BootstrapPath) of\n"
   "        {ok, Bin} -> [{\"bootstrap.beam\", Bin} | ArchiveEntries];\n"
   "        _ -> ArchiveEntries\n"
   "    end,\n"
   "    {ok, Escript} = escript:create(binary, [\n"
   "        shebang,\n"
   "        {emu_args, \"+sbtu +A4 -s bootstrap start\"},\n"
   "        {archive, FinalEntries, []}\n"
   "    ]),\n"
   "    file:write_file(OutputPath, Escript),\n"
   "    io:format(\"Escript written to ~s (~p bytes)~n\", [OutputPath, byte_size(Escript)]),\n"
   "    init:stop().\n"))

(def helper-path (str output-dir "/build_escript.erl"))
(spit helper-path erl-helper)

;; Create bootstrap module that calls Gleam's main entry point
(def bootstrap-erl
  (str "-module(bootstrap).\n"
       "-export([start/0]).\n"
       "start() ->\n"
       "    'hermes_beam@@main':main(init:get_plain_arguments()).\n"))
(def bootstrap-path (str beam-dir "/bootstrap.erl"))
(spit bootstrap-path bootstrap-erl)

;; Compile bootstrap module into ebin
(let [compile-bootstrap (p/shell {:out :string :err :string}
                                (str "erlc -o " beam-dir " " bootstrap-path))]
  (when (pos? (:exit compile-bootstrap))
    (println "Bootstrap compile failed:")
    (println (:err compile-bootstrap))
    (System/exit 1)))

;; Compile the escript builder helper
(let [compile-result (p/shell {:dir output-dir :out :string :err :string}
                             (str "erlc -o " output-dir " " helper-path))]
  (when (pos? (:exit compile-result))
    (println "Erlang compile failed:")
    (println (:err compile-result))
    (System/exit 1)))

(let [run-cmd (str "erl -noshell -pa " output-dir " -s build_escript build -extra " escript-path)
      run-result (p/shell {:dir output-dir :out :string :err :string} run-cmd)]
  (println (:out run-result))
  (when (pos? (:exit run-result))
    (println "Escript creation warning:")
    (println (:err run-result))))

;; Make it executable
(when (fs/exists? escript-path)
  (fs/set-posix-file-permissions escript-path "rwxr-xr-x"))

;; Create convenience wrapper at project root
;; Find all ebin directories in the build output
(def all-ebin-dirs
  (->> (fs/list-dir (str project-root "/build/dev/erlang"))
       (filter #(fs/directory? %))
       (map #(str % "/ebin"))
       (filter fs/exists?)))
(def pa-args (str/join " " (map #(str "-pa " %) all-ebin-dirs)))

(def wrapper-path (str project-root "/hermes"))
(spit wrapper-path
      (str "#!/bin/sh\n"
           "exec erl -noshell " pa-args " -eval \"'hermes_beam@@main':main(init:get_plain_arguments())\" -extra \"$@\"\n"))
(fs/set-posix-file-permissions wrapper-path "rwxr-xr-x")

;; Cleanup helper
(fs/delete-if-exists helper-path)
(fs/delete-if-exists (str output-dir "/build_escript.beam"))

(step "Release complete!")
(println "")
(println (str "  Binary: " escript-path))
(println (str "  Wrapper: " wrapper-path))
(println "")
(println "Usage:")
(println "  ./hermes              # Start REPL")
(println "  ./hermes --doctor     # Run diagnostics")
(println "  ./hermes --onboard    # Run onboarding wizard")
(println "  ./hermes --telegram   # Start Telegram gateway")
(println "  ./hermes --discord    # Start Discord gateway")
(println "  ./hermes --a2a        # Start A2A protocol server")
(println "")
(println "NOTE: Erlang/OTP 26+ must be installed on the target machine.")
