# Git Diff Generation Script

## Purpose
This document outlines the script developed to generate a unified git diff and save it to `patch.diff`.

## Implementation
- The script utilizes Babashka to execute shell commands in a Clojure-based environment.
- It captures the output of the `git diff HEAD` command and saves it to a specified file.

## Code
```clojure
(let [output-file "patch.diff"
      command ["git" "diff" "HEAD"]]
  (try
    (let [result (clojure.java.shell/sh (first command) (second command) (nth command 2))]
      (spit output-file (:out result))
      (println "Diff saved to" output-file))
    (catch Exception e
      (println "Error running git diff:" (.getMessage e))))
```

## Testing
- Once implemented, the script should be tested for different scenarios:
  - Changes detected
  - No changes
  - Running in non-git directories

## Lessons Learned
- Capture and manage output from shell commands effectively.
- Implement robust error handling to enhance user experience.