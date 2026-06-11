# Patterns for Git Operations with Babashka

## Pattern 1: Creating and Saving a Git Diff

### Problem
Need to generate a diff between the current git state and the last commit.

### Solution
Use Babashka's ability to call shell commands to run `git diff HEAD` and save the output to a file.

### Implementation
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

### Considerations
- Test the implementation in different git states (clean, modified, untracked files).
- Ensure error handling for running the command in non-git directories.