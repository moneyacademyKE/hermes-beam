# Gap Analysis: UDS Connection Management, Auto-healing, and Diagnostics

## 1. Introduction
This document performs a Rich Hickey Gap Analysis comparing different approaches for Unix Domain Socket (UDS) connection management, auto-healing, and failure diagnostics within the Babashka workers of `hermes-agent`.

---

## 2. Feature Comparison Matrix

| Feature | Option A: Naive/Current Loop | Option B: Standard NIO Retry | Option C: Rich Hickey Robust Auto-Healing & Diagnostics |
| :--- | :--- | :--- | :--- |
| **Max Retry Control** | Hardcoded loop count (4 attempts total) | Dynamic/Configurable | Strict 3-attempt limit with precise counting |
| **Basic Error Logs** | Yes (Prints exception message) | Yes (Stacktrace dump) | Yes (Human-readable + context-aware messages) |
| **File Presence Check**| No | No | Yes (Checks socket path existence) |
| **Parent Dir Inspection**| No | No | Yes (Checks parent directory permissions & existence) |
| **Connection State Check**| No | No | Yes (Differentiates Connection Refused, No Such File, etc.) |
| **Resource Safety** | Channel is closed | Channel is closed | Channel is closed immediately, preventing file descriptor leaks |
| **Actionable Advice** | No | No | Yes (Suggests permissions check, socket deletion, or server state review) |

---

## 3. Explanations of Feature Differences

### 1. Max Retry Control
* **Option A**: Runs 4 times total (1 initial + 3 retries) due to a standard 1-based decrement of `retries` starting at 3.
* **Option B**: Usually implemented with standard count check, which can be hard to adjust or mock.
* **Option C**: Strictly limits connection attempts to exactly three (1 initial and 2 retries, or 3 attempts total). It tracks retry count precisely and prints `Attempt X/3`.

### 2. Error Diagnostics & Filesystem Inspection
* **Option A/B**: Merely reports JVM exception message (e.g. `Connection refused` or `No such file or directory`), which can be cryptic to developers who don't know the physical state of the socket.
* **Option C**: If a connection fails, it actively queries the JVM `java.nio.file.Files` API to inspect:
  - If the socket file exists at the target path.
  - If the parent directory exists.
  - The read/write permissions of the current user on the target path and parent directory.
  - Provides custom diagnostics based on the type of Exception (e.g., distinguishing `NoSuchFileException` or `ConnectException`).

### 3. Actionable Failure Output
* **Option C** ends with a structured diagnostic summary block when the loop is exhausted. This helps developers immediately isolate if the issue is a permission mismatch, a dead server process, or a cleaned-up socket.

---

## 4. Complexity vs. Utility

| Option | Implementation Complexity | Runtime Overhead | Diagnostic Utility | Reliability |
| :--- | :--- | :--- | :--- | :--- |
| **Option A (Current)** | Very Low | Negligible | Low | Moderate |
| **Option B (NIO Basic)**| Low | Negligible | Moderate | Moderate |
| **Option C (Rich Robust)**| Medium | Negligible | High | High |

---

## 5. Benefits and Trade-offs

### Option A (Current)
* **Benefits**: Extremely simple implementation; minimal lines of code.
* **Trade-offs**: Hard to debug when socket fails; no filesystem context; may do more/fewer retries than requested.

### Option C (Rich Robust)
* **Benefits**: Clear, actionable error reports on failure; exactly 3 attempts; safe resource release.
* **Trade-offs**: Slightly more code to maintain in `worker.clj`.

---

## 6. Actionable Recommendation

We recommend **Option C (Rich Robust)**. The power/utility of having instantaneous, detailed diagnostics when UDS fails outweighs the minor code complexity of the Clojure filesystem checks. 

### Recommended Action Plan
1. Update `worker.clj` to use exactly three connection attempts.
2. Implement `diagnose-uds-failure` in `worker.clj` to run when a connection attempt fails.
3. If the final retry attempt fails, print a comprehensive diagnostics table and exit with status 1.
4. Ensure the supervisor's port reader handles worker exits and logs them correctly.
