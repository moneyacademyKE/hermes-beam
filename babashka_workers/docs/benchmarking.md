# Benchmarking with Clojure

## Overview
- This document details how to perform performance benchmarks in Clojure using Babashka.

## Example Benchmark
- Counting to 1,000,000:
  ```clojure
  (let [start-time (System/nanoTime)]
    (dotimes [n 1000000] (inc n))
    (let [end-time (System/nanoTime)]
      (println (str "Execution time: " (/ (- end-time start-time) 1e6) " milliseconds"))))
  ```