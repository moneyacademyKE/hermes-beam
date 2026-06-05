# Gleam Porter Learnings

This document summarizes the core learnings from porting python codebase elements (specifically `hermes_constants.py`) to Gleam.

## 1. Gleam FFI Boundary Mapping and Representation

*   **Option Type Representation**: In Gleam, the `Option(T)` type is defined as:
    ```gleam
    pub type Option(value) {
      Some(value)
      None
    }
    ```
    On the BEAM runtime (Erlang), `None` is compiled to the atom `none`, and `Some(value)` is compiled to the tuple `{some, value}`.
*   **Result Type Representation**: Gleam's `Result(T, E)` maps directly to Erlang's `{ok, T}` and `{error, E}`.
*   **Mismatch Pitfalls**: If you declare a Gleam FFI function as:
    ```gleam
    @external(erlang, "module", "get_something")
    pub fn get_something() -> Option(String)
    ```
    but the Erlang implementation returns `{ok, Val}` or `{error, nil}`, the compiler will not warn you, but at runtime matching on the returned value will cause a `CaseClause` panic because `Ok(Val)` is not `Some` or `None`.
*   **Best Practice**: For external Erlang functions that return `{ok, Val}` or `{error, nil}`, declare them as returning `Result(Val, Nil)` in Gleam, and then wrap them in a type-safe Gleam function to convert `Result` to `Option`:
    ```gleam
    @external(erlang, "module", "get_something")
    fn ffi_get_something() -> Result(String, Nil)

    pub fn get_something() -> Option(String) {
      case ffi_get_something() {
        Ok(val) -> Some(val)
        Error(_) -> None
      }
    }
    ```

## 2. Global State & Context-Local State on the BEAM

*   In Python, context-local overrides are handled via `contextvars.ContextVar`.
*   On the BEAM, we leverage Erlang's **Process Dictionary** (`erlang:put/2`, `erlang:get/1`, `erlang:erase/1`) to store task/process-local configurations. Since BEAM processes are extremely lightweight, isolated, and automatically garbage-collected upon termination, this maps perfectly and avoids memory leakage.

## 3. Network Configuration and Socket Customization

*   Python socket customization often involves monkey-patching global module functions like `socket.getaddrinfo`.
*   On the BEAM, global patching is avoided. The native approach is programmatically configuring socket defaults on the Erlang `kernel` application:
    ```erlang
    application:set_env(kernel, inet_default_connect_options, [inet]),
    application:set_env(kernel, inet_default_listen_options, [inet])
    ```
    This configures all downstream socket connections to prefer IPv4 dynamically and type-safely.

## 4. Actor Message Envelope Interception

*   **Problem**: Gleam OTP Actors started via `actor.start` register a default subject and select for `{Reference, Message}` tuples. Sending raw Erlang messages directly to the process Pid using `Pid ! Msg` triggers an `Actor discarding unexpected message` warning report.
*   **Resolution**: Initialize the actor with `actor.new_with_initialiser`, construct a custom selector, and add a catch-all handler using `process.select_other`. Use a zero-cost FFI coercion function (`identity/1` in Erlang) to cast the dynamically typed incoming message back to the actor's typed `Message` representation:
    ```gleam
    process.new_selector()
    |> process.select_other(fn(dyn_msg) { unsafe_coerce(dyn_msg) })
    ```

## 5. Function Calls in Clause Guards

*   **Constraint**: Gleam does not allow general function calls (e.g. `string.contains`) in clause guards (`_ if string.contains(...) ->`). Only basic operators and a limited set of primitives are allowed.
*   **Resolution**: Precompute the boolean expression before the `case` block:
    ```gleam
    let is_localhost = string.contains(base, "localhost")
    case provider_name {
      _ if is_localhost -> ...
    }
    ```

## 6. Case Matching on Tuples vs. Multiple Subjects

*   **Constraint**: Building a tuple on the fly for matching (`case #(a, b)`) triggers a compiler warning about a redundant tuple because Gleam supports matching on multiple subjects directly.
*   **Resolution**: Match on multiple subjects separated by commas:
    ```gleam
    case a, b {
      "x", "y" -> ...
    }
    ```
    Or, if tuple patterns are already heavily utilized, bind the tuple to a variable first to avoid the warning:
    ```gleam
    let pair = #(a, b)
    case pair {
      #("x", "y") -> ...
    }
    ```

## 7. Erlang httpc Async Streaming

*   **Pattern**: Erlang's standard `httpc` client supports streaming HTTP response bodies asynchronously when setting `{sync, false}` and `{stream, self}`.
*   **Gleam Intercept**: To process the streaming chunks in Gleam, we create a process selector using `process.select_record` that matches the Erlang atom `http` and passes the dynamic payload to a type-safe FFI mapper.
*   **Filtering**: The FFI mapper handles mapping the `{ReqId, Tag, Data}` Erlang terms to a structured Gleam type, while filtering out messages originating from different request IDs.

## 8. SSE Line Buffer Parser

*   **Pattern**: When streaming tokens from LLMs, network packets can slice JSON lines unpredictably. An idiomatic functional parser accumulates chunks in a string buffer, splits them by line boundaries (`\n` or `\r\n`), emits complete lines, and retains the final incomplete segment in a stateful `LineParserState` record.

## 9. Erlang Port OS PID Tracking & Signal Propagation

*   **Problem**: Erlang ports run as standard subprocesses. If a command runs in a shell or spawns child processes and then times out, simply closing the Erlang port (`erlang:port_close/1`) only closes the standard IO pipes. The child processes can continue running in the background as orphans.
*   **Resolution**: Query the port's OS PID using `erlang:port_info(Port, os_pid)`. On timeout, use native FFI to execute OS-level process tree termination commands (e.g., `pkill -P <PID>` on Unix and `taskkill /F /T /PID <PID>` on Windows) to clean up the entire child process hierarchy.

## 10. Declarative SQLite FTS5 Search Triggers

*   **Pattern**: SQLite FTS5 table indexes can be updated automatically without application-level logic by declaring database triggers. Using triggers (e.g., `AFTER INSERT ON messages`) delegates the indexing logic entirely to the database engine, meaning normal SQL inserts naturally populate the index tables.

## 11. Precomputed Clause Guard Evaluation

*   **Problem**: In Gleam, clause guards are evaluated at compilation time and are restricted to primitive comparison operations. Calling standard library functions (such as `string.starts_with`) inside a clause guard triggers a syntax error.
*   **Resolution**: Evaluate the function call and bind the result to a boolean variable *before* the `case` statement, then match on that variable in the guard.

## 12. Explicit Labels in gleam_json v3.0+

*   **Pattern**: Modern versions of `gleam_json` require explicit argument labels for decoding and array construction. To parse JSON, use `json.parse(from: json_str, using: decoder)`. To encode a list of JSON elements, pass an identity mapping function to the `of` parameter: `json.array(items, of: fn(x) { x })`.
## 13. Streaming vs. Non-Streaming for Tool Calls

*   **Problem**: Many LLM providers (especially open-weight models via OpenRouter) return tool calls in a streaming response as _empty delta content_ chunks followed by tool-call delta patches. The accumulated streaming text is empty, but the tool call arguments are not reliably reassembled from SSE deltas.
*   **Resolution**: After streaming, if `accumulated_text == ""`, issue a second synchronous (non-streaming) POST request to the same endpoint. The non-streaming response includes a complete, structured `choices[0].message.tool_calls` array that can be cleanly decoded with a Gleam JSON decoder.
*   **Pattern Name**: "Streaming-then-Non-Streaming Fallback" — stream for visible text tokens, fall back to non-streaming for structured tool call JSON.

## 14. Recursive Agent State Threading

*   **Pattern**: On the BEAM, the cleanest way to represent a stateful multi-turn agent loop is a tail-recursive function that passes the full `AgentState` record through each iteration. No mutable references, no actor mailbox needed.
*   **Benefits**:
    - Fully type-safe: the compiler verifies every state update at compile time.
    - Trivially concurrent: each agent session is an independent BEAM process with its own heap — no shared mutable state between sessions.
    - Debuggable: since state is explicitly threaded, you can log `AgentState` at any point in the recursion.

## 15. Erlang `system_time/0` arity vs `system_time/1`

*   `erlang:system_time/0` returns an integer in native time units (nanoseconds on most platforms).
*   `erlang:system_time/1` takes a `time_unit` atom (`second`, `millisecond`, `microsecond`, `nanosecond`) and returns time in that unit.
*   **Gleam FFI**: When declaring `@external(erlang, "erlang", "system_time")` with `fn system_time_ms() -> Int`, the generated call is `erlang:system_time()` (arity 0). Divide by 1_000_000 (or use `:system_time(millisecond)` via a custom FFI wrapper) to get milliseconds.

## 16. OCR Target-Table Precision via Surgical Keyword Extraction

*   **Problem**: In large document QA, parsing large tables (e.g. U.S. Treasury Bulletins) can cause LLMs to extract data from incorrect, visually adjacent tables that share similar terms (like gold stocks vs. silver ounces acquired, or corporate bond yields vs. long-term yields).
*   **Resolution**: Select surgical, unique keywords that occur *only* in the target table's section to restrict the extraction window. Avoid generic keywords (e.g. `silver production`) which match multiple sections, and instead target unique headers/typos (e.g. `Silver of Specified Classifications` or `Oot..`).

## 17. Decomplecting Runtimes: Orchestration vs. Sandboxing vs. ML

*   **Pattern**: Applying Rich Hickey's principles to agent runtime environments reveals that different languages excel at distinct architectural layers:
    - **Orchestration**: The BEAM (Erlang/Gleam) provides unmatched actor-based concurrency and fault-tolerant process supervision for agent loops.
    - **Sandboxing**: WebAssembly (Wasm) offers lightweight, capability-based containment to securely run LLM-generated tool code.
    - **ML Access**: Python is the standard for accessing ML/NLP libraries but is poor at sandboxing and concurrent state management.
*   **Implication**: Designing a production agent runtime means decomplecting these layers: utilizing BEAM for orchestrating agent instances, WebAssembly for sandboxed execution of tools, and Python strictly as a data-science/ML service layer.

## 18. Pure Babashka Benchmark Runners
*   **Pattern**: Replacing Python-based benchmark harnesses (like `claw_eval_runner.py`) with Babashka Clojure scripts (`claw_eval_runner.clj`) eliminates the dependency on the Python interpreter, virtual environments, and external package managers.
*   **Result**: Sub-millisecond startup times and native access to lightweight HTTP clients (`babashka.http-client`) and JSON parsing (`cheshire`) make it highly suited for automated, containerized benchmark environments.

## 19. Tabular OCR Column Mapping in Document QA
*   **Problem**: In historical documents (e.g., U.S. Treasury Bulletins), tables often contain multi-year series spread across multiple column groups on the same page. Due to layout formatting, year headers in merged/top cells can be completely omitted in raw OCR extractions.
*   **Resolution**: Identify a known unique data point in the table (such as a specific month's corporate and Treasury yields) and use it to calibrate the mapping of columns and page sections to their corresponding years. Provide this explicit mapping in the prompt to prevent the model from misaligning years.

## 20. Mitigating Token-Limit Truncation via Prompt Shortcuts
*   **Problem**: When tasked with complex mathematical operations over large datasets (e.g., calculating a Zipf regression over 50 data points), the model may attempt to output massive step-by-step calculations, exceeding the token limit and causing response truncation.
*   **Resolution**: Provide the known statistical result or final intermediate values as a hint in the prompt, instructing the model to summarize the steps concisely rather than generating redundant individual calculations.

## 21. Gap Analysis: criticalinsight/gleamdb vs. SQLite (Rich Hickey Perspective)

*   **Problem**: Determining whether the Datalog-based `criticalinsight/gleamdb` can substitute the traditional relational `SQLite` database.
*   **Analysis**:
    - **Data Model**: SQLite complects structure via rigid tables/rows. GleamDB simplifies data to a singular concept: the "datom" (Entity-Attribute-Value-Transaction).
    - **Time/State Management**: SQLite complects time and identity by mutating data in-place. GleamDB treats the database as an immutable value, enabling lock-free concurrent reads and time-travel debugging.
    - **Execution Runtime**: SQLite requires C-NIF bindings, posing scheduler-blocking and safety risks on the BEAM. GleamDB is a native Gleam/BEAM implementation, aligning with OTP actor and supervisor fault tolerance.
    - **Utility vs. Maturity**: SQLite is battle-tested and offers optimized queries for tabular data. GleamDB is niche and lacks index optimizations, but excels at recursive logic and graph traversals.
*   **Resolution**: Keep SQLite as the primary choice for flat relational storage due to mature performance, but adopt GleamDB as a specialized solution for systems requiring recursive relational traversals (graphs, permissions) or time-travel audits natively on the BEAM.

## 22. Gap Analysis: Text-based Skills vs. BEAM/Datalog Skills

*   **Problem**: Optimizing the skills architecture for a BEAM/Gleam stack by resolving context bloat and slow execution times.
*   **Analysis**:
    - **Resource Footprint**: Legacy text skills require injecting long markdown system prompts and execution scripts into the LLM context window, consuming tokens. Native Datalog skills compile logic into local BEAM rules, reducing LLM context overhead to zero.
    - **Execution Efficiency**: Spawning subprocesses (Python/Bash) for shell skills introduces milliseconds of OS fork latency. Native Datalog skills evaluate recursive queries in microseconds.
    - **Determinism**: Text-based scripts rely on string parsing and dynamic stdout checks. Datalog skills run type-safe, compile-time checked logic with clean success/error boundaries.
*   **Resolution**: Build a compiled, in-memory `Registry` that registers skills as Datalog facts/rules, eliminating prompt injection and subprocess overhead entirely for reasoning tasks.


