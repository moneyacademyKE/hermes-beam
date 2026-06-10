# Gap Analysis: JVM-Dependent vs. JVM-Free Architectures for Babashka Workers

> [!NOTE]
> **Post-Implementation Update (June 2026)**
> Since this gap analysis was performed, the architecture transitioned to a 100% JVM-Free model. Instead of relying on a JVM-based DataScript/Chicory dependency, we implemented a pure-Clojure micro-Datalog interpreter directly in the native Babashka worker environment (`worker.clj`) and execute WASM tools natively via standard subprocess execution. This has successfully eliminated all JDK/JRE runtime dependencies on the worker side, enabling native GraalVM-compiled Babashka performance with startup times of under 10ms.

This document presents a Rich Hickey Gap Analysis comparing the JVM-dependent architecture (using Java-based Chicory WASM runtime and Maven dependency resolution) against a JVM-free architecture (using vendored pure Clojure DataScript and native/CLI-based WASM execution).

---

## 1. Feature Set Difference Matrix

| Feature | JVM-Dependent (Chicory + Maven) | JVM-Free (Vendored DataScript + CLI/Node WASM) | Difference Explanation |
| :--- | :--- | :--- | :--- |
| **WASM Runtime Engine** | JVM-Native (Chicory Interpreter/AOT) | Host-Native (`wasmtime`, `wasmer`, or JS engine) | Chicory runs entirely within the JVM heap using Java classes. JVM-Free offloads to an external precompiled native WASM CLI runner. |
| **WASM Performance** | Medium (Interpreted/AOT on JVM) | High (JIT/AOT compiled via LLVM/Cranelift) | Native CLI runners like `wasmtime` compile WASM to host machine code, outperforming JVM interpreters. |
| **Clojure Dependency Resolution** | Dynamic via Maven (`tools.deps` / `bb.edn`) | Static/Vendored (Sources check-in or manual classpath) | Maven resolution via `bb.edn` spawns a JVM to resolve dependencies from Clojars/Maven Central. JVM-Free uses pure-Clojure library sources checked in directly. |
| **Memory Footprint** | Large (JVM Heap overhead, minimum ~50-100MB) | Extremely Small (Native Babashka binary, ~10-20MB) | The JVM heap and class definition space consume significant memory. The native `bb` binary is compiled via GraalVM and has sub-millisecond startup and negligible memory overhead. |
| **Deployment Complexity** | High (Requires a JDK/JRE installed on the host) | Low (Zero-install, standalone `bb` binary) | JVM-dependent requires the target machine to have OpenJDK configured. JVM-free only requires the `bb` binary and optionally a WASM CLI. |
| **Sandbox Security** | High (Chicory JVM sandbox) | Extremely High (Wasmtime sandboxing / OS process isolation) | Both provide memory and syscall sandboxing. Native `wasmtime` provides robust, production-tested capability-based security (WASI). |

---

## 2. Benefits and Trade-Offs

### JVM-Dependent (Chicory + Maven)
*   **Benefits**:
    *   **In-Process Execution**: WASM and Clojure run in the same JVM memory space, allowing direct object sharing and avoiding process spawning overhead.
    *   **Ease of Dependency Management**: Simply list packages in `bb.edn` and let Babashka handle resolution.
*   **Trade-Offs**:
    *   **Requires JVM**: The host system must have a JDK/JRE installed (e.g., OpenJDK 21/26), which goes against the lightweight nature of standalone Babashka.
    *   **Slower Startup**: Resolving classpaths and launching in JVM mode adds ~100-200ms latency to worker startup.

### JVM-Free (Vendored DataScript + Native CLI)
*   **Benefits**:
    *   **No JVM Required**: Works entirely with the native `bb` binary compiled via GraalVM.
    *   **Sub-Millisecond Startup**: Native `bb` starts instantly (<10ms), accelerating agent loops.
    *   **High Performance**: Native WASM runners are significantly faster than Chicory's interpreter.
*   **Trade-Offs**:
    *   **Vendoring Overhead**: Third-party Clojure libraries (like DataScript) must be vendored (checked in as source files) or downloaded ahead-of-time.
    *   **External CLI Dependency**: Requires a native WASM CLI tool (like `wasmtime`) to be present on the host PATH.

---

## 3. Complexity vs. Utility

| Metric | JVM-Dependent (Chicory) | JVM-Free (Native CLI) |
| :--- | :--- | :--- |
| **Implementation Complexity** | Low (Dependencies declared in `bb.edn`) | Medium (Need to vendor DataScript and invoke CLI process) |
| **Runtime Complexity** | High (JVM lifecycle, classpath resolution, classloading) | Low (Direct process execution, OS-level containment) |
| **System Footprint** | High (JRE installation required) | Low (Standalone binaries only) |
| **Developer Ergonomics** | Good (Standard Maven/JVM ecosystem) | Excellent (Zero setup, instant startup) |

---

## 4. Actionable Recommendation

We recommend the **JVM-Free (Native CLI)** approach if the host environment is constrained or if we want to minimize external software requirements (e.g., avoiding global JDK installations). However, because we already have **OpenJDK 26** installed and successfully passing all tests on the user's Mac, the current JVM-based implementation is fully functional and certified.

---

## 5. JVM-Free (Babashka Native) Implementation Blueprint

If we transitioned the system to be 100% JVM-Free, we would modify our implementation as follows:

### A. Vendoring DataScript Natively
DataScript is a pure Clojure library. We would download its source `.clj` files and place them directly in the workspace directory under `babashka_workers/src/datascript/`. We would then remove `datascript` from `bb.edn` `:deps`.
Babashka can load it natively using:
```clojure
(require '[datascript.core :as d])
```
Since it runs on Babashka's native interpreter (SCI), it requires zero JVM classloading at runtime.

### B. Executing WASM Natively via Subprocess
Instead of importing Java classes from Chicory in `worker.clj`, we would delegate WASM execution directly to `wasmtime` or `wasmer` via the native shell:

```clojure
;; JVM-Free local WASM execution handler using native subprocesses
(defn run-wasm-func-native [module-path func-name args-list]
  (let [args-str (clojure.string/join " " args-list)
        ;; Invoke wasmtime CLI tool
        {:keys [out err exit]} (p/sh "wasmtime" "run" "--invoke" func-name module-path args-str)]
    (if (= exit 0)
      ;; Output contains the returned integer(s)
      (let [result-ints (mapv #(Integer/parseInt %) (clojure.string/split (clojure.string/trim out) #"\s+"))]
        (json/generate-string result-ints))
      (throw (Exception. (str "Native WASM execution failed: " err))))))
```

This ensures the entire worker executes natively under the GraalVM native binary with <10ms startup times, requiring only the standard `bb` binary and a `wasmtime` installation on the host system.
