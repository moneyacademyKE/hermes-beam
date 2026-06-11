# Patterns for HTTP Requests and File Writing in Babashka

## Pattern: Fetching and Writing Headers
1. Use `babashka.curl` for HTTP requests.
2. Extract the desired parts of the response (e.g., headers).
3. Use `spit` for writing data to files.