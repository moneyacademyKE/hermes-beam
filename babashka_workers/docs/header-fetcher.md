# Header Fetcher Script

## Overview
This script fetches headers from an HTTP GET request to `https://httpbin.org/get` and saves them to `headers.txt`.

## Implementation
1. Fetched headers using `babashka.curl`
2. Saved the response headers to `headers.txt` using `spit`.