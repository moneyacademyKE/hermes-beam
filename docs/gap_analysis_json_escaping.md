# Gap Analysis: JSON-RPC Payload Escaping in IPC Streams

## 1. Introduction
This document performs a Rich Hickey Gap Analysis comparing different approaches for escaping string fields (like user prompts) in JSON-RPC payloads sent over Unix Domain Sockets (UDS).

---

## 2. Feature Comparison Matrix

| Feature | Option A: Naive Replaces (Current) | Option B: Erlang FFI Escaping | Option C: Pure Gleam Escaping Pipeline |
| :--- | :--- | :--- | :--- |
| **Escapes Quotes** | Yes | Yes | Yes |
| **Escapes Newlines**| No | Yes | Yes |
| **Escapes Backslashes**| No | Yes | Yes |
| **Dependencies** | None | Erlang library/custom FFI | None |
| **Robustness** | Low (Crashes on newlines/backslashes) | High | High |
| **Implementation Effort** | Very Low | Low | Low |

---

## 3. Explanations of Feature Differences

### 1. Robustness & Stream Demarcation
Unix Domain Sockets transfer stream bytes. To frame JSON payloads, the supervisor uses a `\n` newline suffix.
* **Option A**: Does not escape newlines. If a prompt has literal newlines, the payload is split across lines, corrupting the JSON frame and causing parse errors on the worker.
* **Option B/C**: Safely replaces all literal newlines with `\n` characters, keeping the JSON string on a single line and preserving correct UDS line-based message framing.

---

## 4. Complexity vs. Utility

| Option | Implementation Complexity | Runtime Overhead | Utility | Reliability |
| :--- | :--- | :--- | :--- | :--- |
| **Option A (Current)** | Very Low | Negligible | Low | Low |
| **Option B (FFI)** | Low | Negligible | High | High |
| **Option C (Pure Gleam)** | Low | Negligible | High | High |

---

## 5. Actionable Recommendation

We recommend **Option C (Pure Gleam)**. It provides a simple, direct, and zero-dependency solution that runs purely inside Gleam, eliminating compile-time/runtime FFI mismatch risks while fully resolving the newline socket-framing bug.

### Recommended Action Plan
1. Add `escape_json_string` function to `subagent_supervisor.gleam`.
2. Escape the `prompt`, `base_url`, and `api_key` values in the JSON-RPC payload builder.
3. Verify the fix using both automated tests and end-to-end runs.
