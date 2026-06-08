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

## 23. Gap Analysis: Legacy Python Components vs. Erlang/OTP BEAM Ports

*   **Problem**: Identifying high-utility components in the legacy Python codebase and evaluating the architectural gaps when porting them to the Erlang/OTP BEAM stack.
*   **Analysis**:
    - **Parallel Batch Runner (`batch_runner.py`)**: Python complects parallel execution via OS subprocess forks (`multiprocessing`), causing high memory footprint and slow start times. On BEAM, we can run concurrent task pools using lightweight processes.
    - **Platform Gateway (`gateway/`)**: Python handles platform adapters (Telegram, Discord, Slack, etc.) using async loops that can block on CPU tasks or lock up the entire runner. On BEAM, each adapter runs under a separate supervision tree (OTP supervisors), meaning socket crashes or errors in one adapter do not affect others.
    - **SQLite Session Indexer (`hermes_state.py`)**: Python relies on file/thread locks to handle SQLite transactions, resulting in write contention. On BEAM, we can serialize writes inside a dedicated `GenServer` actor while executing read operations concurrently, avoiding locking overhead.
*   **Resolution**: Prioritize porting the **Parallel Batch Runner** as the next high-utility component to unlock native multi-core task scheduling and isolation, followed by the **Platform Gateway** to leverage OTP fault tolerance.

## 24. Gap Analysis: LLM Prompt-Injected Skills vs. Evolutionary Datalog Skills

*   **Problem**: Designing an optimal skills framework that resolves prompt clutter, subprocess latency, and enables autonomous agent self-improvement.
*   **Analysis**:
    - **LLM Prompt-Injected Skills**: Requires feeding descriptions of all available tools/skills in the system prompt. The LLM must reason step-by-step to coordinate relationships, consuming tokens and risking logical breakdown. Self-improvement requires rewriting file assets.
    - **Evolutionary Datalog Skills**: Decomplects instruction from execution. Skills are registered as EAVT datoms and recursive logic rules. The LLM is only exposed to a single database query interface (`query_facts`), delegating recursive reasoning (routing, access control) entirely to the local in-memory query engine. Self-improvement is modeled as a genetic mutation-test loop where the LLM writes new rules/facts, tests them in a dynamic registry sandbox, and registers them directly to SQLite on success.
*   **Resolution**: Adopt Evolutionary Datalog Skills to achieve zero token bloat, microsecond local reasoning speeds, and robust, automated, database-persisted self-improvement loops.

## 25. Homoiconic Datalog Rule Serialization as Datoms

*   **Problem**: How to persist dynamic Datalog rules inside a flat, standard relational EAVT database schema without introducing complex multi-entity joins or database locking.
*   **Resolution**: Deconstruct the logic rule `Rule(head, body)` into a list of standard `Datom` records by using a flat, positional key-encoding scheme for attributes. We store head components under attributes `rule/head_0`, `rule/head_1`, `rule/head_2`, and each body clause `i` under attributes `rule/body_i_0`, `rule/body_i_1`, `rule/body_i_2`.
*   **Outcome**: Rules are stored as pure data facts, enabling standard Datalog queries to read, inspect, and reason over active rules within the database itself.

## 26. Acyclic Dependency Management in Gleam

*   **Problem**: Gleam does not allow circular imports between modules (e.g. A -> B -> A). In complex architectures involving persistence actors (`state_actor.gleam`), database schema handlers (`hermes_state.gleam`), and serialization domain logic (`evolutionary.gleam`), circular references are easy to introduce if serialization needs to write to actors, and actors need to call serialization.
*   **Resolution**: Keep domain logic modules completely pure and decoupled from persistence-specific actors. By having `evolutionary.gleam` depend only on raw database connections (`sqlight.Connection`) rather than actor subjects, and allowing the state actor to orchestrate deserialization, we completely break compile-time cycles while maintaining full end-to-end integration.

## 27. Microsoft SkillOpt Optimization Loops on Datalog Runtimes

*   **Problem**: How to optimize Datalog skills dynamically without breaking existing system behavior or causing regressions on prior validation criteria.
*   **Resolution**: Adopt the Microsoft SkillOpt paradigm. We represent skill modifications as a union type of discrete edits (`Patch`: `AddRule`, `DeleteRule`, `ReplaceRule`, etc.). We evaluate candidate skill configurations against a suite of held-out validation checks, and optimize by accepting only patches that yield a strict improvement in the check pass-ratio (the validation gate), rejecting score-decreasing modifications.





## 28. Robust Non-Streaming Fallbacks on SSE Stream Timeouts

*   **Problem**: In Gleam (`hermes_beam`), Erlang's `inets` HTTP client, when streaming LLM responses via SSE over SSL, can buffer the chunks in certain network environments instead of emitting them progressively. This causes the stream collector `stream_and_collect` to block and eventually trigger a `StreamTimeout`, leaving the accumulated streaming text buffer empty (`""`).
*   **Bug**: If the agent's non-streaming fallback only parses and returns tool calls (expecting text to have been fully collected by the stream), any text content returned by the fallback is completely discarded, resulting in a false-negative `[No response from model]` failure.
*   **Resolution**: Refactor the fallback system to return a union `AgentResponse` (representing either `ToolCalls` or `FinalText`), and update the agent loop (`agent_turn_loop`) to handle both cases on fallback. This ensures that even when streaming fails due to networking buffer/latency issues, the agent falls back and captures the complete, valid text response.

## 29. Vite React TypeScript strict checks on Framer Motion

*   **Problem**: In strict React/TypeScript project configurations (specifically with `verbatimModuleSyntax` and strict unused checks), dynamic resolution of motion components (e.g. `motion[as as keyof typeof motion]`) causes compilation errors: `Type instantiation is excessively deep and possibly infinite.` and `Expression produces a union type that is too complex to represent.`.
*   **Resolution**:
    - For components where dynamic elements are required, cast the resolved component directly to `any` (e.g., `const Component = motion[as] as any`) to bypass the compiler's deep union checks.
    - Where possible, avoid dynamic elements entirely by using a concrete `<motion.div>` wrapper, which drastically reduces compiler type checking load.
    - Ensure all unused imports and variables are clean, as strict configurations treat warnings as fatal compiler errors.

## 30. Dual Frontend Asset Pipeline & Dev Port Collision Handling

*   **Problem**: Running multiple concurrent React SPA dashboards and portfolios (e.g. `web/` and `jack-portfolio/`) under local Vite dev servers can lead to port collisions on default port `5173`.
*   **Resolution**:
    - Vite handles port collision natively by automatically trying sequential ports (e.g. falling back to `5174` if `5173` is occupied) and printing the active URL to stdout.
    - For production packaging, Vite builds must compile to the expected target directory (e.g. `hermes_cli/web_dist/` for the Python FastAPI server) so they can be statically served by the backend.
    - Always run `npm install` in individual workspaces to resolve dependencies (`tsc` compiler, plugins) before executing production builds.

## 31. Native Web Serving with Mist + Wisp in Gleam/BEAM Stack

*   **Problem**: Relying on Node/npm development servers in production or runtime packages complects the stack with Node.js runtime environments, which increases disk space, execution latency, and dependency auditing overhead.
*   **Resolution**:
    - Build/compile the frontend SPA once to static assets (like `/dist`).
    - Use native Gleam `mist` + `wisp` servers under BEAM supervision.
    - Serve the static files from the `dist` folder natively via Wisp middleware: `use <- wisp.serve_static(req, under: "/", from: dist_path)`.
    - If the request path does not exist on disk, fallback gracefully to reading and returning `index.html` to support client-side SPA routing (e.g., `/projects`, `/about`).

## 32. Dynamic Directory Resolution with FFI get_cwd in Erlang/Gleam

*   **Problem**: Hardcoding absolute directory paths in Gleam source code breaks when files are moved or deployed to different machines/environments.
*   **Resolution**:
    - Declare a simple zero-dependency Erlang FFI `file:get_cwd()` wrapper:
      ```erlang
      get_cwd() ->
          case file:get_cwd() of
              {ok, Cwd} -> {ok, list_to_binary(Cwd)};
              {error, Reason} -> {error, Reason}
          end.
      ```
    - Map this to `utils.get_cwd()` in Gleam, and combine with `constants.path_join` to dynamically resolve static asset paths relative to the starting directory.

## 33. Comprehensive Rich Hickey Gap Analysis (hermes_beam vs. hermes-agent)

*   **Problem**: Establishing a clear architectural comparison and finding technical parity/trade-offs between the new Gleam/BEAM implementation (`hermes_beam`) and the legacy Python implementation (`hermes-agent`).
*   **Resolution**: 
    - **Complecting vs. Decomplecting**: The legacy Python implementation complects session mutation, CLI interfaces, and environment sandboxing. The new Gleam/BEAM implementation decomplects these using isolated functional actors (`iteration_budget`), pure data structures for states, and native FFI boundaries.
    - **Database as a Value**: Instead of mutating relational tables, `hermes_beam` employs `gleamdb` to represent state as a set of immutable EAV Datoms `(Entity, Attribute, Value, Tx)`. Point-in-time database snapshots are queried as static values, eliminating mutation side effects.
    - **Execution Robustness**: Using Erlang Ports (`hermes_exec.gleam`) and native PID signal propagation (`pkill -P` / `taskkill /T`) prevents orphaned subprocesses on timeout, resolving a major resource leak vulnerability in the legacy runner.
    - **Utility vs. Complexity**: While the BEAM runner has a simpler CLI/REPL and lacks complex sandboxes (Docker, Singularity), it provides superior fault-tolerant concurrency (OTP supervisors), static type-safety guarantees, and a low execution footprint.

## 34. Actor-Isolated SQLite Writer Pattern

*   **Problem**: In concurrent environments on the BEAM, direct SQLite connections (`sqlight.Connection`) can experience write contention, resulting in `SQLITE_BUSY` errors. Furthermore, carrying database connection handles inside domain state records complects state with connection lifecycle management.
*   **Resolution**:
    - Decouple time and identity by wrapping the SQLite connection in an OTP Actor (`state_actor.gleam`).
    - The actor serializes all database writes sequentially via its inbox, preventing locking conflicts and contention.
    - Expose asynchronous/synchronous client APIs (e.g., `create_session`, `insert_message`, `update_session_cwd`, `end_session`) that send message envelopes to the actor process and wait for the response.
    - Update domain state records (like `AgentState` and `REPLState`) to hold a `StateActor` reference instead of a raw database connection.

## 35. Datalog Skill Compiler & Loader (Rich Hickey Decomplecting)

*   **Problem**: Loading prompt-injected or text-based skill definitions often complects text parsing, file loading, and agent state storage.
*   **Resolution**: Deconstruct the loading sequence into two isolated layers:
    - **Pure parsing** (`parse_skill_file`): Takes raw file contents as a `String`, splits it on delimiters, parses key-value metadata, and maps the markdown prompt body to EAV facts (`[Datom(name, "skill/prompt", prompt)]`), with zero side-effects.
    - **File IO / Persistence** (`load_skills_from_dir`): Scans directories using `simplifile.read_directory` and reads `SKILL.md` inside nested subfolders. The dynamic results are then transacted sequentially to the SQLite database via the `state_actor` GenServer mailbox, resolving all locks and keeping time/identity clean.

## 36. JSON-RPC TUI Gateway in Gleam

*   **Problem**: Establishing a standard JSON-RPC gateway to interact with TUIs/dashboards while working with Gleam's strict decoding structure.
*   **Resolution**:
    - **Optional Fields Decoding**: Gleam's `gleam/dynamic/decode` requires explicit arity/default parameters. When decoding optional fields (like `id` or `params` in JSON-RPC envelopes), use `decode.optional_field("key", None, decode.optional(decode.dynamic))` to handle both absent fields and `null` values cleanly.
    - **Interactive Session Gateway**: Ingest JSON-RPC request envelopes from `stdin` via recursive reading (`utils.read_line`). Keep agent instances thread-safe and isolated in `GatewayState` by mapping `session_id` to their respective `AgentState`.
    - **Streaming Event Push**: Intercept and push agent event callbacks (`message.delta`, `tool.start`, etc.) onto `stdout` as JSON-RPC notifications while executing `run_conversation` synchronously.

## 37. Terminal TUI Frontend Architectures (React/Ink vs. Clojure/charm.clj vs. BEAM/ex_ratatui)

*   **Problem**: Selecting the optimal terminal frontend architecture to minimize accidental complexity and optimize cross-platform code reuse.
*   **Resolution**:
    - **Ecosystem & Layout Parity**: React/TypeScript/Ink leveraging Yoga (CSS Flexbox) provides a far simpler, declaratively scalable styling boundary than manual Clojure box math or constraint-based layout splits in Ratatui.
    - **Platform Independence vs. Reuse**: Stdio-based JSON-RPC messaging isolates UI concerns (client) from execution (server), allowing JS-based frontends (Ink, Electron, browser xterm.js) to share autocomplete logic, syntax highlighting, and UI themes directly, maximizing reuse.
    - **Supervision & Safety**: In BEAM environments, calling Rust Ratatui bindings via Rustler NIFs (`ex_ratatui`) complects the UI rendering process with the Erlang scheduler, risking VM crashes on panic/segmentation faults, whereas stdio-based clients are cleanly isolated.

## 38. Babashka/Clojure Elm-Style TUI Client Implementation

*   **Problem**: Implementing a lightweight, fast-booting, deterministic terminal TUI client that replaces heavy Node/npm JS dependencies while maintaining Elm-style (Model-Update-View) loop parity and robust asynchronous subprocess communication.
*   **Resolution**:
    - **Fast-Booting Babashka Runtime**: Using Babashka `bb` resolves the slow JVM startup time, booting the TUI instantly (<50ms).
    - **Elm-style Loop with `charm.clj`**: By employing Timo Kramer's `charm.clj`, we implement clean model updates and render functional views with curated colors and borders.
    - **Non-blocking Process IO in Go Blocks**: To prevent blocking the UI event loop during synchronous reads from the subprocess stdin/stdout, we create a recursive read command `read-line-cmd` wrapped in a `charm/cmd`. Since `charm.clj` executes `cmd` functions inside core.async `go` block thread pool threads, the blocking read runs in a background thread and deposits the parsed JSON-RPC events directly onto the UI message channel, avoiding rendering lag.
    - **Process Lifecycle Guarding**: To avoid leaving zombie subprocesses (e.g. `tui_gateway`), we wrap the main program `run` in a `try ... finally` block, calling `proc/destroy` on the subprocess when the UI exits or throws an exception.
    - **Testing Isolation**: To prevent top-level execution triggers from launching the main TUI loop during namespace loading (e.g., when requiring files inside `clojure.test` suites), we guard the `-main` execution entrypoint with a check against the system property: `(when (= *file* (System/getProperty "babashka.file")) (apply -main *command-line-args*))`.

## 39. Python Code Retirement & Babashka-Based CLI Launcher

*   **Problem**: Retaining a hybrid system that relies on a Python-based CLI wrapper (`cli.py`, `hermes_cli/main.py`) alongside a Gleam backend (`hermes_beam`) and a Clojure TUI client (`ui-clj`) introduces accidental complexity, slow startup latency, and dual package configurations (both Erlang/Gleam and Python packaging pipelines).
*   **Resolution**:
    - **Full Codebase Retirement**: Delete the legacy Python codebase entirely, including the 100+ packaging and command-definition modules.
    - **Unified Babashka Entrypoint**: Implement the root launcher executable `hermes` as a lightweight Clojure script running on Babashka (`#!/usr/bin/env bb`).
    - **Process Context and Working Directory Isolation**: When executing downstream Babashka sub-scripts (like `ui-clj/src/hermes_tui.clj`) that depend on local `bb.edn` dependency configurations, the launcher must spawn them with their process working directory explicitly set to the sub-project directory (e.g. `ui-clj/`). This allows Babashka to resolve relative path dependencies and compile the classpath cleanly, avoiding `FileNotFoundException` or class-loading errors when launched from other root directories.
    - **Arguments Pass-Through**: Subcommands like `repl` are resolved dynamically and forwarded to the Gleam backend (`gleam run --`) via `babashka.process/process`, preserving stdout/stderr inheritance and raw exit codes.

## 40. Extensibility through Model Context Protocol (MCP) in pure BEAM/Gleam

*   **Problem**: While the core Datalog engine (`gleamdb`) allows for clean logical reasoning inside the agent, executing side-effects (e.g., executing scripts, managing files) directly in the BEAM virtual machine violates isolation, complects state, and demands writing many custom Erlang/Gleam wrappers for standard APIs.
*   **Resolution**: 
    - **Delegation to MCP**: Instead of rewriting all agent capabilities in Gleam, we implement a lightweight Model Context Protocol (MCP) Client over standard IO pipes. The agent core remains strictly functional, delegating side effects to decoupled MCP server binaries.
    - **Erlang Ports for Async Communication**: By wrapping `erlang:open_port` using `{spawn, Cmd}` with standard IO piping, we construct a fully asynchronous streaming `mcp_client`. 
    - **JSON-RPC State Machine**: The MCP client uses Gleam's OTP `process.selecting` to asynchronously handle stream responses and dispatch JSON-RPC message IDs back to awaiting callers, fully avoiding blocking operations in the core Agent loop.
    - **Dynamic Schema Stitching**: At runtime, the client resolves available capabilities (`tools/list`), mapping them into OpenAI's `tools` JSON schema, effectively stitching dynamic external capabilities back into the stateless LLM query cycle.


### Decomplecting I/O and Core Logic (Rich Hickey Style)
* **Date**: 2026-06-08
* **Context**: Migrating `tui_gateway.gleam` and `hermes_tui.clj` to asynchronous models.
* **Learning**: Blocking I/O (like `utils.read_line` or `.readLine` in a main loop) fundamentally complects time with execution. By pushing I/O to the edges (spawned reader processes or `core.async` threads) and feeding channels/subjects, we restore the ability to evaluate intents purely and reactively. 
* **Impact**: `hermes_tui.clj` now uses `clojure.core.async` to asynchronously fold over incoming lines and broadcast intents without blocking the main event loop, dramatically improving UI responsiveness and system stability. `tui_gateway` uses Erlang/Gleam `process.receive` rather than `select` blocks when transforming streams, providing immutable message handling.
