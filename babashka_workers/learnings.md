# Learnings from HTTP Header Fetching Script

In this task, I implemented a Clojure script using Babashka to fetch HTTP headers from a specified URL. The approach utilized Babashka's built-in capabilities, specifically `babashka.curl`, to achieve this.

## Key Points:
- **Tool Used**: Babashka
- **URL Fetched**: https://httpbin.org/get
- **Output File**: headers.txt

## Result:
The headers received were:
- date: Thu, 11 Jun 2026 03:04:38 GMT
- content-type: application/json
- content-length: 294
- server: gunicorn/19.9.0
- access-control-allow-origin: *
- access-control-allow-credentials: true

The lesson learned is the importance of using the right tools that fit the task requirements, which in this case was Babashka for simplicity and efficiency.