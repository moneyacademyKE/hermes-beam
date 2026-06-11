# Patterns for Fetching HTTP Headers in Clojure

## Pattern: Using Babashka for HTTP Requests
- **Scenario**: When needing to fetch data from a URL and write to a file.
- **Implementation**:
```clojure
(require '[babashka.curl :as curl])
(spit "output.txt" (pr-str (:headers (curl/get "https://example.com"))))
```
- **Notes**: Using `babashka.curl` is a lightweight approach for quick scripts.