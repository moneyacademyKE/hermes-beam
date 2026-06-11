This document records the process of fetching HTTP headers using Clojure and Babashka.

## Fetching Headers from HTTP
The following script was used:
```clojure
(require '[clojure.java.io :as io])
(require '[babashka.curl :as curl])

(defn fetch-and-write-headers []
  (let [response (curl/get "https://httpbin.org/get")
        headers (:headers response)]
    (spit "headers.txt" (pr-str headers))))

(fetch-and-write-headers)
```

### Observations
- Utilized "babashka.curl" for HTTP requests as "clj-http.client" was not available.
- Successfully wrote headers to "headers.txt".

### Outcome
The headers fetched were:
- Date: Thu, 11 Jun 2026 03:25:07 GMT
- Content-Type: application/json
- Content-Length: 294
- Server: gunicorn/19.9.0
- Access-Control-Allow-Origin: *
- Access-Control-Allow-Credentials: true

This approach is lightweight and integrates well with Babashka.