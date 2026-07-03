# Gap Analysis: nextdoc/ai-tools integration for Hermes BEAM

This document presents a thorough and comprehensive Rich Hickey Gap Analysis comparing our current Clojure/Babashka worker test setup with the capabilities of [nextdoc/ai-tools](https://github.com/nextdoc/ai-tools), a Babashka task utility for TDD workflows over nREPL.

---

## 1. Context and Decomplecting Analysis

From a Rich Hickey perspective, **complecting** (braiding together) runtime orchestration, dependency resolution, JVM startup, and test execution results in slow, complex, and fragile feedback loops. 

*   **Our Current Setup**: The Babashka worker daemon (`worker.clj`) runs tests using a basic `run-tests` function inside a spawned subprocess or runs Clojure evaluation (`bb_eval`) inside a stateful namespace. While simple, it does not support connecting to external JVM nREPL environments, does not track changed namespaces dynamically, and does not filter out stack trace noise. For ClojureScript, we have no built-in test runner or build-switching logic.
*   **nextdoc/ai-tools**: Decomplectes the *test runner client* (a lightweight Babashka script) from the *test execution runtime* (an active JVM or Shadow-CLJS process running an nREPL server). Communication occurs strictly via the nREPL bencode protocol. It utilizes `tools.namespace` to only reload modified files, preserving an epochal state model where only modified changes are transacted to the running system, ensuring near-instantaneous test feedback.

---

## 2. Feature Set Difference Matrix

| Feature | Local Babashka Worker Setup | nextdoc/ai-tools | Feature Explanation & Difference |
| :--- | :--- | :--- | :--- |
| **Orchestration Client** | Direct process execution (`bb <file.clj>`) | nREPL-client via Babashka tasks (`bb nrepl:test`) | Local runs tests in a fresh or stateful interpreter. `ai-tools` eval code inside a persistent running REPL. |
| **Namespace Reloading** | Manual reloading or restart of daemon | Dynamic reloading via `tools.namespace.repl/refresh` | Local complects code updates with process lifecycles. `ai-tools` queries modified files and refreshes them in-memory. |
| **Granular Test Target** | Run entire test namespace | Specific test namespaces OR individual test vars (`ns/test-var`) | `ai-tools` supports slash notation for targeting single functions, reducing execution time and context. |
| **Stack Trace Filtering** | Raw JVM/Babashka/SCI stack traces | Regex-based frame filtering with transparency statistics | `ai-tools` removes noisy framework internals (e.g. `sci.impl`, `clojure.lang`) and retains only user-space frames. |
| **ClojureScript Support** | None | Shadow-CLJS build switching & async polling runner | `ai-tools` implements custom session management and async polling to collect test results from Shadow-CLJS runtimes. |
| **Machine-Readable Output**| Raw text output | XML tags wrapper (`<test-results>...</test-results>`) | ClojureScript results are formatted inside XML tags for easy, deterministic parsing by LLM coding agents. |

---

## 3. Benefits and Trade-offs

### nextdoc/ai-tools
*   **Benefits**:
    *   **Sub-second TDD Loop**: Eliminates the ~1–3s JVM startup cost on every test run.
    *   **Agent-Optimized Diagnostics**: Stack trace filtering keeps LLM context clean, preventing token waste on framework internals. XML wrappers allow reliable output parsing.
    *   **Dynamic State Preservation**: Running tests over nREPL leaves system state intact (e.g. database connections, in-memory caches), which aligns with the REPL-driven development ethos.
*   **Trade-offs**:
    *   **Requires Active Server**: A background nREPL server (JVM or Shadow-CLJS) must be started and maintained (`.nrepl-port` file must be present).
    *   **Dependency on tools.namespace**: The project being tested must list `org.clojure/tools.namespace` as a dependency.

### Current Local Setup
*   **Benefits**:
    *   **No Active Daemon Required**: Tests run standalone, making it perfect for cold CI/CD pipelines.
    *   **Zero Infrastructure Overhead**: No need to manage nREPL ports, socket states, or session timeouts.
*   **Trade-offs**:
    *   **Complected State**: Every run executes from a fresh state, which makes test iterations slow and resource-heavy.
    *   **No ClojureScript Integration**: Cannot test browser or frontend CLJS modules dynamically.

---

## 4. Complexity vs. Utility Matrix

| Metric | Local Babashka Worker Setup | nextdoc/ai-tools |
| :--- | :--- | :--- |
| **Implementation Complexity** | Low (Basic script run) | Medium (Bencode socket protocol, session cloning) |
| **Runtime Complexity** | Low (Single-process CLI lifecycle) | Medium (Two-process architecture, socket state) |
| **Developer Feedback Loop** | Medium (~2-3s delay) | Instant (<100ms over nREPL) |
| **Token Efficiency (for Agents)** | Low (Verbose stack traces, unformatted text) | High (Filtered traces, clean XML tags) |
| **ClojureScript Capability** | Zero | High (Dynamic Shadow-CLJS testing) |

---

## 5. Weighted Power/New Capabilities vs. Speed vs. Complexity vs. Trade-offs Analysis

We apply a weighted score (1 to 10 scale) to determine the value of integrating `nextdoc/ai-tools` into our project.

| Evaluation Metric | Weight | Local Setup Score | nextdoc/ai-tools Score | Weighted Difference |
| :--- | :--- | :--- | :--- | :--- |
| **Agent Autonomy & TDD Speed** | 30% | 5 / 10 | 10 / 10 | +1.50 |
| **Token Efficiency / Noise Reduction**| 25% | 4 / 10 | 9 / 10 | +1.25 |
| **ClojureScript Verification** | 20% | 0 / 10 | 8 / 10 | +1.60 |
| **System Footprint & Simplicity** | 15% | 9 / 10 | 6 / 10 | -0.45 |
| **Setup & Dependency Overhead** | 10% | 10 / 10 | 7 / 10 | -0.30 |
| **Total Weighted Score** | **100%**| **5.05** | **8.65** | **+3.60** |

**Conclusion**: The addition of `nextdoc/ai-tools` provides a substantial positive net value (+3.60). The minor trade-off in setup complexity is heavily outweighed by the massive gains in test execution speed, token efficiency, and ClojureScript support for TDD agent loops.

---

## 6. Actionable Implementation Plan

To bridge this gap in the `ayncoder` codebase, we will take the following actions:

1.  **Configure Dependencies**:
    *   Add `babashka/nrepl-client` and `nextdoc/ai-tools` as dynamic git deps to `babashka_workers/bb.edn`.
2.  **Define Tasks**:
    *   Expose the `nrepl:test` and `nrepl:test-shadow` tasks in `babashka_workers/bb.edn` to make them CLI-accessible.
3.  **Create Test Scenarios**:
    *   Write a mock nREPL test loop in `babashka_workers/test` to verify nREPL test execution, stack trace cleaning, and individual test execution.
4.  **Verification**:
    *   Execute the new tasks using Babashka.
    *   Verify they exit with code 0 on success and code 1 on failure.
    *   Confirm stack trace cleaning works correctly.
