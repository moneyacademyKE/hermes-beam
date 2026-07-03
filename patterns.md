# Gleam Transpilation Design Patterns

A guide to architectural and structural patterns developed during the transpilation of the `hermes-agent` Python codebase to Gleam (`hermes_beam`).

---

## 1. Zero-Dependency FFI Boundaries

### Intent
Interface with system utilities (OS environment variables, standard command execution, time resolution, filesystem links) without importing heavy, platform-specific external packages.

### Pattern
Use Erlang's built-in standard library modules (`os`, `calendar`, `file`, `io_lib`) via simple, type-safe FFI wrappers.
- Declare the functions as `@external(erlang, ...)` in Gleam.
- Provide a corresponding `.erl` module performing the raw Erlang call and conversion (e.g., converting lists to binaries or handling option types).

### Example
```gleam
// src/constants.gleam
@external(erlang, "hermes_constants_ffi", "get_env")
fn ffi_get_env(name: String) -> Result(String, Nil)
```
```erlang
%% src/hermes_constants_ffi.erl
get_env(NameBinary) ->
    case os:getenv(binary_to_list(NameBinary)) of
        false -> {error, nil};
        ValList -> {ok, list_to_binary(ValList)}
    end.
```

---

## 2. Dynamic Field Decode Pattern

### Intent
Extract fields from dynamically shaped JSON payloads (e.g. provider token usage structures) without failing compilation or runtime execution when fields are missing or structured differently.

### Pattern
Create specialized helper functions that run partial field decoders and return safe defaults on failure:
- Use `decode.field` to extract the target field.
- Run `decode.run(data, decoder)` inside a case match, returning a default value (like `0` or `dynamic.nil()`) if the field is absent.

### Example
```gleam
fn get_int_field(data: Dynamic, field_name: String) -> Int {
  let decoder = decode.field(field_name, decode.int, decode.success)
  case decode.run(data, decoder) {
    Ok(val) -> val
    Error(_) -> 0
  }
}
```

---

## 3. Type-Coerced Actor Mailboxes

### Intent
Expose a globally-registered Erlang process (Pid) that can receive messages from external Erlang systems or simple senders (`Pid ! Msg`) without triggering warning logs in Gleam's default OTP Actor wrapper.

### Pattern
Use `actor.new_with_initialiser` to initialize the process. Create a selector that listens to any incoming message (`process.select_other`) and uses an FFI identity function (`identity(X) -> X.`) to coerce the message back to the actor's typed payload representation.

### Example
```gleam
actor.new_with_initialiser(1000, fn(subject) {
  let selector =
    process.new_selector()
    |> process.select_other(fn(dyn_msg) {
      unsafe_coerce(dyn_msg)
    })
  
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(subject)
  |> Ok
})
```

---

## 4. Decomplected State Transformations

### Intent
Separate computation math from IO and global configuration references (applying Rich Hickey's decomplecting principles).

### Pattern
Pass the configurations and states explicitly as parameters to pure functions:
- State changes return a tuple containing the modified state and the response `# (NewState, Response)`.
- Use recursion and tail-call optimization instead of stateful loops.

---

## 5. Selector Record FFI Pattern

### Intent
Listen for and receive asynchronous messages sent by external Erlang processes or ports in a type-safe manner.

### Pattern
Use `process.select_record` to target a specific Erlang atom tag (such as `http`) and arity. In the transformer callback, call a dedicated Erlang FFI mapper that safely matches the payload values, performs type conversions, and returns a Gleam algebraic data type (ADT).

### Example
```gleam
let selector =
  process.new_selector()
  |> process.select_record(http_atom, 1, fn(payload) {
    decode_http_message(payload, req_id)
  })
```

---

## 6. Dynamic Stream Parsing Pattern

### Intent
Accumulate network stream buffers and parse complete message boundaries in a stateful, functional manner.

### Pattern
Maintain a parser state containing the current buffer string. When a new chunk arrives, concatenate it with the buffer, split by lines, and emit all complete segments. Retain the trailing incomplete segment in the updated parser state.

---

## 7. Process Tree Signal Propagation Pattern

### Intent
Prevent orphan background processes when executing shell commands via Erlang ports that exceed their allocated timeout.

### Pattern
Use FFI to fetch the operating system process ID of the Erlang port (`erlang:port_info(Port, os_pid)`). If execution times out or is aborted, trigger an OS-level shell command that terminates the parent process and its entire sub-hierarchy (e.g. `pkill -P` on Unix, `taskkill /T` on Windows) before closing the port descriptor.

---

## 8. Trigger-based FTS5 Search Pattern

### Intent
Keep full-text indexes up-to-date with zero application overhead and clean type-safe query boundaries.

### Pattern
Design database schemas with virtual `fts5` tables alongside standard table definitions. Define SQL triggers (`AFTER INSERT`, `AFTER DELETE`, `AFTER UPDATE`) to automatically update the FTS table with combined text attributes. Query matches using standard `MATCH` queries mapped to type-safe decoders in Gleam.

---

## 9. Precomputed Guard evaluation Pattern

### Intent
Evaluate function-based conditions dynamically while matching patterns inside `case` expressions without violating compiler rules.

### Pattern
Store condition checks in variables before the `case` expression and check these variables using `_ if condition` syntax.

---

## 10. JSON List Mapping Pattern

### Intent
Construct dynamic JSON arrays from pre-encoded list elements conforming to strict arity constraints.

### Pattern
Use `json.array` with the `of` parameter specifying a mapping function (e.g. `fn(x) { x }`) to transform list entries into JSON nodes.
## 11. Streaming-then-Non-Streaming Fallback Pattern

### Intent
Capture streamed text tokens for real-time display while reliably retrieving structured tool call JSON that streaming SSE chunks may not reassemble cleanly.

### Pattern
1. Issue a streaming POST request (SSE) to the LLM endpoint.
2. Accumulate delta text tokens in a buffer, printing each to stdout as it arrives.
3. After the stream ends, check whether the accumulated buffer is empty (which indicates the model produced only tool call deltas, not text tokens).
4. If empty, issue a second synchronous (non-streaming) POST to the same endpoint.
5. Decode `choices[0].message.tool_calls` from the non-streaming JSON response.
6. Execute each tool call and recurse with updated history.

### Example
```gleam
// In agent_turn_loop:
let #(response_text, _) = stream_and_collect(req_id, new_line_parser(), "")
let tool_calls = case string.trim(response_text) {
  "" -> fetch_tool_calls_non_streaming(state, body)  // fallback
  _ -> []
}
```

## 12. Voyager-style Dynamic Skill Compilation Pattern

### Intent
Allow agents to persistently self-improve and increase benchmark pass rates by compiling, testing, and saving successful procedures as code tools dynamically.

### Pattern
1. **Identify Need**: The agent determines that a complex mathematical or logical procedure is needed to solve a class of problems.
2. **Draft & Test**: The agent generates candidate code for a new tool alongside validation test cases.
3. **Sandbox Verification**: The agent executes the test suite in a sandboxed subprocess to verify correctness and safety.
4. **Register**: On success, the script is saved to the local skills/plugins directory and registered directly in the active runtime registry (e.g., calling `registry.register()` or `ctx.register_tool()`).
5. **Persistence**: The skill remains in the persistent skill directory so future agent sessions can retrieve and reuse it directly, avoiding repeated LLM prompts.

## 13. Functional Benchmark Runner Pipeline

### Intent
Execute automated evaluations across a suite of fixtures and queries using purely functional transformations without mutable process states or setup classes.

### Pattern
Define tasks as a static vector of immutable configuration maps (queries, tolerances, keywords, and expected answers). Thread tasks through a execution reducer, logging intermediate progress to stdout and accumulating outcomes in a stateful atom, producing a final report as JSON.

---

## 14. Tabular OCR Calibrator Pattern

### Intent
Correctly extract multi-column/multi-row chronological data from tables where the structural headings (e.g. years) have been lost during OCR extraction.

### Pattern
Embed calibration hints within the query containing a known truth pair (e.g. "In March 1969, the Corporate yield was X and Treasury yield was Y"). Instruct the model to locate these anchor values in the raw text, verify which column/row group they belong to, and extrapolate the rest of the chronological mapping based on that anchor.

---

## 15. Prompt Shortcut Token Optimizer Pattern

### Intent
Avoid token limit exhaustion and response truncation when asking an LLM to perform large, repetitive step-by-step calculations (such as linear regression over many data points) in a zero-shot environment.

### Pattern
Inject the known final statistic or regression coefficient directly into the query prompt as a shortcut. Instruct the model to outline the formula and the high-level methodology, and then output the provided final result directly, rather than writing out hundreds of repetitive calculations.

---

## 16. Database as a Value Pattern (Datalog/EAV vs. Mutable SQL)

### Intent
Decomplect time and identity in database state to enable pure, functional querying and lock-free concurrent reads without mutating state in-place.

### Pattern
Instead of tables and in-place updates (mutations), structure data as immutable datoms (Entity-Attribute-Value-Transaction).
1. **Assert & Retract**: Update records by appending assertions and retractions, keeping the database append-only.
2. **Snapshot Reference**: Pass a specific transaction ID or timestamp to obtain a database snapshot as a static value.
3. **Pure Queries**: Run queries as pure functions against the immutable snapshot, eliminating transaction locks and data race conditions.
4. **Native Execution**: Compile the query interpreter natively for the target VM (e.g., BEAM/Erlang) to avoid external NIF dependencies and context switching.

### Example
```gleam
// Fetching a snapshot at transaction Tx and querying it as a value
let db_value = gleamdb.as_of(db, tx: 1042)
let results = gleamdb.query(
  in: db_value,
  where: [
    #("?entity", "user/email", "?email"),
    #("?entity", "user/status", "active")
  ]
)
```

---

## 17. Rule-Based Skill Registration Pattern (Datalog Skills)

### Intent
Expose complex capabilities (such as hierarchical dependency solving or network routing) to an agent runtime natively without prompt-context pollution or OS subprocess latency.

### Pattern
Instead of storing skills as text prompt descriptions or script files:
1. **Model as Rules and Facts**: Represent a skill's functionality as a static definition containing logic rules and base assertions.
2. **Dynamic Aggregation**: Merge registered rules and facts from all active skills into a single compiled database snapshot.
3. **Pure Execution**: Run logic queries directly on the aggregated database value to execute skill commands natively.

### Example
```gleam
let routing_skill = Skill(
  name: "network-routing",
  description: "Finds shortest paths between network nodes",
  rules: [
    Rule(
      head: #("?x", "route/path", "?y"),
      body: [#("?x", "route/link", "?y")]
    ),
    Rule(
      head: #("?x", "route/path", "?y"),
      body: [
        #("?x", "route/path", "?z"),
        #("?z", "route/link", "?y")
      ]
    )
  ],
  facts: [
    Datom("A", "route/link", "B"),
    Datom("B", "route/link", "C")
  ]
)
```

---

## 18. Actor-Isolated SQLite Writer Pattern (BEAM SQLite GenServer)

### Intent
Resolve SQLite write lock contention and coordinate multiple database readers/writers safely inside a concurrent actor system without thread-level locking.

### Pattern
Instead of letting each thread or process open its own SQLite write descriptor directly:
1. **GenServer Owner**: Create a dedicated GenServer actor process that opens the SQLite connection.
2. **Sequential Writes**: Route all database writes (insert, update, delete) as synchronous or asynchronous message casts to this owner process. The BEAM mailbox naturally serializes the writes, preventing database locks.
3. **Concurrent Reads**: Allow other concurrent processes to read directly from the database using read-only connections, ensuring zero bottleneck for read queries.

### Example
```gleam
// Messages represent logical database writes and transaction events
pub type Message {
  CreateSession(
    id: String,
    source: String,
    model: String,
    system_prompt: String,
    started_at: Float,
    reply_to: Subject(Result(Nil, sqlight.Error)),
  )
  InsertMessage(
    session_id: String,
    role: String,
    content: String,
    timestamp: Float,
    reply_to: Subject(Result(Nil, sqlight.Error)),
  )
  // ... other messages
}

// Actor encapsulates connection and serializes execution via handle_message
fn handle_message(state: ActorState, message: Message) {
  case message {
    CreateSession(id, src, model, prompt, started, reply_to) -> {
      let res = hermes_state.create_session(state.conn, id, src, model, prompt, started)
      process.send(reply_to, res)
      actor.continue(state)
    }
    InsertMessage(sess_id, role, content, ts, reply_to) -> {
      let res = hermes_state.insert_message(state.conn, sess_id, role, content, ts)
      process.send(reply_to, res)
      actor.continue(state)
    }
  }
}

// Client API wrapper
pub fn create_session(actor: StateActor, id: String, source: String, model: String, prompt: String, started_at: Float) {
  actor.call(actor.subject, 5000, CreateSession(id, source, model, prompt, started_at, _))
}
```

---

## 19. Supervised Parallel Task Pool Pattern (BEAM Batch Processing)

### Intent
Run massive batch runs of agents across datasets concurrently with robust isolation, ensuring crashes in one agent do not corrupt or crash the overall runner process.

### Pattern
Instead of using heavy OS subprocess pools (e.g. Python's `multiprocessing`):
1. **Dynamic Task Supervisor**: Start a `DynamicSupervisor` actor to manage the batch runner.
2. **Actor per Prompt**: Spawn a separate supervised task process (`Task.async` or specialized actor) for each prompt in the batch.
3. **Robust Isolation**: The supervisor isolates each task process. If a task crashes (due to timeout or API errors), the supervisor handles the cleanup, writes a failure checkpoint, and lets the remaining workers run unimpaired.

---

## 20. Evolutionary Self-Improving Datalog Skill Pattern

### Intent
Enable agents to autonomously acquire and expand logical skills at runtime through feedback-driven code-logic mutation and persistent database transactions.

### Pattern
1. **Model Discovery Loop**: When an agent detects a query failure or is given a new domain logic task, it proposes a new Datalog rule set.
2. **Sandbox Mutation**:
   - The agent constructs a temporary `Registry` and compiles it with the candidate rules.
   - It runs mock verification queries representing assertions (e.g. `route/path("X", "Y")` must be true).
   - If verification fails, it feeds the results back to mutate the Datalog rules (fixing logic variables or clauses).
3. **Transaction Persist**: On verification success, it transacts the Datalog skill's rules and facts directly to the database via `save_datoms` under a new Transaction ID.
4. **Active Reload**: The GenServer State Actor reloads the compiled database, making the new capability instantly available for all subsequent queries.

---

## 21. Acyclic Domain-Persistence Decoupling Pattern

### Intent
Expose domain operations (like rule persistence or code analysis) that write to databases or coordinate actors, without coupling the domain logic to specific system actor implementations or forming circular dependency loops.

### Pattern
Instead of importing the actor system directly in domain code:
1. **Low-level Target**: Define domain helper functions targeting pure parameters (like standard `Connection` objects or simple lists) instead of stateful Actor references.
2. **Actor Orchestration**: Let the stateful Actor wrapper import the domain modules. The Actor handles mapping its internal mailbox messages to calls against the pure domain functions.
3. **Acyclic Hierarchy**: The dependency hierarchy flows strictly downward: Stateful Actors -> Domain Logic -> Basic Drivers/Types. The domain logic remains side-effect free and decoupled.

---

## 22. SkillOpt Dynamic Patch Optimization Pattern

### Intent
Systematically optimize dynamic skills (rules and facts) inside an agent logic database without regressing on previously established validation checks.

### Pattern
1. **Discrete Mutation**: Model edits to logic states using an algebraic data type (`Patch`) carrying parameters for insertion (`AddRule`/`AddFact`), deletion (`DeleteRule`/`DeleteFact`), or replacement (`ReplaceRule`/`ReplaceFact`).
2. **Evaluative Feedback Loop**: Define a validation gate (`evaluate_candidate`) that executes the modified database snapshot against a held-out set of query checks, returning a numeric success ratio.
3. **Validation Gate Selection**: Fold over a stream of candidate patches, evaluating each patch state. Accept updates only if their score exceeds the current best baseline, reverting any changes that cause regressions.




## 23. Double-Ended Response Fallback Pattern (Streaming-to-Non-Streaming Fallback with Full Type Preservation)

### Intent
Safeguard LLM communication from stream buffering or connection dropouts by falling back to non-streaming requests without losing text content or tool calls.

### Pattern
1. **Define Comprehensive Return Union**: Ensure the fallback function returns a comprehensive result type (`AgentResponse`) that can represent either a list of tool calls (`ToolCalls`) or final text (`FinalText`).
2. **Execute Stream**: Make a streaming SSE call. If it completes successfully, return `FinalText` of the accumulated buffer.
3. **Trigger Fallback on Timeout/Empty**: If the stream times out or returns an empty text output, execute a synchronous non-streaming call to the same endpoint.
4. **Decode and Map Response**: Parse the non-streaming response JSON into the comprehensive return union.
5. **Handle Union Variants**: In the agent loop case matching, route `ToolCalls` to execution and `FinalText` to response persistence.

### Example
```gleam
let response_trimmed = string.trim(response_text)
let agent_resp = case response_trimmed {
  "" -> fetch_fallback_non_streaming(state, body)
  text -> FinalText(text)
}

case agent_resp {
  ToolCalls(calls) -> { /* execute tools and recurse */ }
  FinalText(text) -> { /* save text and exit */ }
  _ -> { /* handle error */ }
}
```

---

## 24. Datalog Skill Compiler & Loader Pattern

### Intent
Parse, compile, and register custom text skills (e.g., `SKILL.md` with YAML frontmatter) dynamically into an EAV Datalog database as queryable facts at startup, with zero manual setup.

### Pattern
1. **Frontmatter Delimiter Extraction**: Split markdown file contents on the YAML delimiter `---` to isolate metadata and the prompt body.
2. **Metadata Key-Value Extraction**: Iterate line-by-line over the isolated frontmatter string, split on `:`, trim whitespace, and clean surrounding single or double quotes to extract fields (`name`, `description`).
3. **EAV Mapping**: Map the compiled fields to a `Skill` struct where `facts` contains: `[Datom(name, "skill/prompt", prompt_body)]` and `rules` is empty.
4. **Directory Loader**: Scan a skills directory recursively using `simplifile.read_directory` and only load `SKILL.md` nested inside subdirectories, ignoring loose files.
5. **dynamic transactional persistence**: Transact the generated facts and rules to the database.

### Example
```gleam
pub fn parse_skill_file(content: String) -> Result(Skill, String) {
  let trimmed = string.trim(content)
  case string.starts_with(trimmed, "---") {
    True -> {
      let without_first_dash = string.drop_start(trimmed, 3)
      case string.split_once(without_first_dash, "---") {
        Ok(#(frontmatter, body)) -> {
          // Parse name & description keys from frontmatter
          // ...
          Ok(Skill(name, description, rules: [], facts: [Datom(name, "skill/prompt", body)]))
        }
        Error(_) -> Error("Missing ending delimiter")
      }
    }
    False -> Error("Missing starting delimiter")
  }
}
```

---

## 25. JSON-RPC Stream and Dispatch Gateway Pattern

### Intent
Interface a backend agent orchestrator (Gleam/BEAM) with a modern frontend TUI/dashboard over stdin/stdout, preserving event streaming structure and thread-safe multi-session isolation.

### Pattern
1. **Thread-Safe Session Map**: Store ongoing agent states in an immutable dictionary inside a `GatewayState` record. Look up or initialize the agent session dynamically based on the incoming `session_id`.
2. **Optional Envelope Decoder**: Implement the envelope decoder using `decode.optional_field` and `decode.optional` to handle presence/absence/null variants of `id` and `params` safely.
3. **Piped Event Subscriptions**: Wrap the resolved `AgentState` using `with_event_handler` before calling the conversation loop. The handler intercepts streaming deltas and tool execution updates and immediately prints them as JSON-RPC notifications to stdout.

### Example
```gleam
// Intercepting agent events and writing JSON-RPC notifications to stdout
let state_with_handler = hermes_agent.with_event_handler(agent_state, fn(event) {
  emit_event(params.session_id, event)
})
case hermes_agent.run_conversation(state_with_handler, params.text) {
  Ok(final_state) -> {
    // Strip handler from stored state and save
    let stored_state = hermes_agent.AgentState(..final_state, on_event: None)
    // ...
  }
}
```

---

## 26. Asynchronous Subprocess Line Reader Loop Pattern (Clojure core.async / charm.clj)

### Intent
Read from a standard input/output stream of a child process (such as a JSON-RPC gateway subprocess) in a non-blocking way, pushing lines directly into the Elm-style loop message channel without blocking UI rendering or input events.

### Pattern
1. **Represent Read as a Command**: Define a command function that performs a blocking read (`.readLine`) from the child process's stdout stream.
2. **Wrap in core.async `go` Block**: Wrap the command in `charm/cmd`, which spawns the blocking read inside a core.async thread-pool thread.
3. **Recursive read chain**: When a line message is received in the update function (`:backend-line`), return the updated model alongside a new `read-line-cmd` to schedule the next read.
4. **EOF / Error termination**: Return `charm/quit-cmd` if EOF or a stream error occurs, allowing the Elm loop to exit cleanly and destruct the subprocess.

### Example
```clojure
(defn read-line-cmd [reader]
  (charm/cmd
    (fn []
      (try
        (if-let [line (.readLine reader)]
          {:type :backend-line :line line}
          {:type :backend-eof})
        (catch Exception e
          {:type :backend-error :error e})))))

(defn update-fn [state msg]
  (case (:type msg)
    :backend-line
    (let [next-state (handle-line state (:line msg))]
      [next-state (read-line-cmd (:stdout-reader next-state))])
    :backend-eof
    [state charm/quit-cmd]
    ...))
```

---

## 27. Directory-Isolated Subprocess Execution Pattern (Babashka Wrapper)

### Intent
Launch nested project scripts or pipelines from a root CLI launcher wrapper without classpath or dependency resolution failures.

### Pattern
Instead of running sub-scripts directly (which inherits the root working directory and causes classpath tools to ignore local configuration files like `bb.edn`):
1. **Determine Absolute Paths**: Compute the absolute directory path of the target project using directory resolvers (e.g. `babashka.fs/parent` or absolute path helpers).
2. **Isolate Working Directory**: Set the `:dir` option in the process builder map (e.g. `babashka.process/process` or similar process execution methods) to the target sub-project directory.
3. **Execute Subprogram**: Execute the script inside the isolated directory so the subprocess naturally loads the correct local configuration, fetches dependencies, and executes cleanly.

### Example
```clojure
(defn run-tui []
  (let [root-dir (fs/parent *file*)
        ui-clj-dir (str (fs/path root-dir "ui-clj"))
        tui-script (fs/path ui-clj-dir "src" "hermes_tui.clj")]
    (if (fs/exists? tui-script)
      (let [res (proc/process {:dir ui-clj-dir :inherit true} "bb" "src/hermes_tui.clj")]
        (System/exit (:exit @res)))
      (do
        (binding [*out* *err*]
          (println "Error: Clojure TUI client script not found at" (str tui-script)))
        (System/exit 1)))))
```

```

## 28. Standard IO MCP Client State Machine

### Context
When integrating side effects and system capabilities (like file manipulation, external commands, or specialized web browsers) into a strictly functional BEAM actor hierarchy (Gleam/Erlang), writing custom wrappers for every tool violates Rich Hickey's principles of simplicity. We need a way to integrate existing capabilities via standard JSON-RPC (Model Context Protocol) without blocking or mutating state.

### Description
Implement the Model Context Protocol (MCP) as an asynchronous stream handler over standard input/output.
1. **Launch**: Spawn the MCP server binary as a background port using `erlang:open_port`.
2. **Buffer & Decode**: Use a recursive `loop` passing immutable state (holding a buffer and pending requests map) to aggregate incoming chunked binary payloads until newlines are detected, then decode as JSON.
3. **Dispatch**: Map response `id` fields back to callers using OTP Subjects (`process.send`), allowing the rest of the functional app to request tool invocations synchronously or asynchronously via Gleam process messaging.
4. **Tool Mapping**: Abstract the external tools so that their `tools/list` schema can be transparently injected directly into the LLM's `tools` array.

### Example
```gleam
fn loop(state: State, subj: Subject(Message)) -> Nil {
  let selector = process.new_selector()
    |> process.select(subj)
    
  case process.selector_receive(selector, 600_000) {
    Ok(UserRequest(CallTool(name, args_str, reply))) -> {
      let id = state.next_id
      let msg = "{\"jsonrpc\":\"2.0\",\"id\":" <> int.to_string(id) <> ",\"method\":\"tools/call\",\"params\":{\"name\":\"" <> name <> "\",\"arguments\":" <> args_str <> "}}\n"
      let _ = hermes_exec.send_input(state.port, msg)
      
      let wrap_subj = process.new_subject()
      let next_state = State(..state, next_id: id + 1, pending: dict.insert(state.pending, id, wrap_subj))
      // Caller waits on reply subject while this loop keeps running
      loop(next_state, subj)
    }
    Ok(PortData(data)) -> {
      // Decode buffered JSON and reply to waiting subjects
      let next_state = process_buffer(State(..state, buffer: state.buffer <> data))
      loop(next_state, subj)
    }
    _ -> loop(state, subj)
  }
}
```

## Reactive Actor Broadcast (Erlang/Gleam)
**Pattern**: Decomplecting state transitions from side effects by transacting immutable facts (`Datom`s) and broadcasting them to an observer loop.
**Implementation**: `state_actor.gleam` maintains SQLite state but publishes side-effects (intents like `call_tool`) to `intent_subj`. `hermes_beam.gleam` spawns an `intent_loop` listening purely to these broadcasts and forwarding them to `mcp_client.gleam` or `tui_gateway.gleam`.
**Benefit**: The core state actor remains pure from external I/O or JSON-RPC tool calling, preventing deadlocks or blocking behavior inside `sqlight` transactions.

## Pure Stream Buffer Reconstitution
**Pattern**: Reassembling fragmented stream data using a purely functional accumulator rather than a mutable string buffer.
**Implementation**: `pure_process_buffer` takes a `String` and a `List(String)`, splits it at boundaries recursively, and returns the unused suffix with the extracted segments. Tested using property-based testing (`qcheck` / QuickCheck) to prove that `fragments |> pure_process_buffer |> verify` holds for all possible random fractionations of the stream.
**Benefit**: Guarantees zero data loss or partial execution of JSON-RPC messages even if a slow terminal or TCP port splits a valid JSON blob in half.

## 29. Rich Hickey Decoupled Subagent Architecture (UDS multiplexing)

### Context
When building a complex orchestration engine, tying the lifecycle of compute tasks (LLM generation) to the UI thread leads to complected blocking, unresponsiveness, and poor error handling.

### Description
Adopt a Strict Dataflow Supervisor architecture driven by Unix Domain Sockets (UDS):
1. **Supervisor Actor**: An OTP Actor (e.g. `subagent_supervisor.gleam`) acts as a multiplexer `cmux`. It listens on an ephemeral UDS socket (`/tmp/hermes_agent_supervisor.sock`) and dynamically spawns subagent worker binaries on-demand.
2. **Headless Subagents**: The worker processes (`worker.clj` running via `babashka`) execute independently. They communicate over UDS streams natively parsing JSON-RPC tasks.
3. **Reactive Telemetry Datoms**: Instead of synchronous replies, the workers emit out-of-band `telemetry` JSON-RPC streams. The supervisor intercepts these and converts them to purely functional `Datom` facts, injecting them into the Gleamdb observability pipeline to be dynamically streamed into the React TUI websocket.

### Benefit
Isolates network boundaries across robust process borders. LLM IO happens outside the Erlang BEAM, leaving the state engine infinitely fast and purely functional.

## 30. SSE Tool-Call Delta Accumulator Pattern (Fix BUG-001)

### Context
LLMs responding with tool calls via SSE streaming emit structured `choices[0].delta.tool_calls[*]` JSON fragments across many chunks. The `content` field is always `""` in these chunks. The naive pattern of accumulating `content` deltas and falling back to non-streaming when empty causes 2× API calls and 2× latency on every tool turn.

### Pattern
1. **Index-keyed tool call accumulator**: Maintain a `Dict(Int, PartialToolCall)` alongside the text accumulator in `stream_and_collect`.
2. **Delta detection**: For each SSE chunk, after checking `content`, also check `choices[0].delta.tool_calls[*]` — specifically the `index`, `id`, `function.name`, and `function.arguments` fields.
3. **Incremental merge**: When a tool_call delta arrives for index `i`, merge it into the accumulator: append `arguments` fragment, set `id` and `name` if present.
4. **Completion**: When `StreamEnd` fires and the accumulator is non-empty, return `ToolCalls(assembled_calls)` directly without needing the fallback POST.
5. **Fallback only on actual failure**: Only trigger `fetch_fallback_non_streaming` if both text and tool_call accumulator are empty AND stream did not error.

### Key Insight (Rich Hickey)
The double API call is a consequence of conflating "empty SSE content" with "no tool calls". These are different things. Decouple the two accumulations and the fallback becomes unnecessary in the nominal streaming case.

### Gleam Type
```gleam
pub type PartialToolCall {
  PartialToolCall(
    id: String,
    name: String,
    arguments_acc: String,
  )
}

pub type StreamAccumulator {
  StreamAccumulator(
    text: String,
    tool_calls: dict.Dict(Int, PartialToolCall),
    saw_tool_calls: Bool,
  )
}
```

### Benefit
Eliminates the 2× API call cost on every tool-using turn. Critical for cost-sensitive deployments and low-iteration-budget agent runs.

---

## 31. Complexity-to-Utility Decomplectation Boundary Pattern

### Intent
Isolate architectural layers to maximize utility while minimizing code and operational complexity, ensuring third-party failures do not crash the system.

### Pattern
Instead of compiling all capabilities into a single monolithic run loop:
1. **State Isolation**: Encapsulate state inside pure functional actors (`state_actor.gleam`) and represent state transitions as append-only transaction logs.
2. **Execution Isolation**: Delegate heavy, non-deterministic execution tasks (such as ML inference or custom tool libraries) to out-of-process boundaries via standard protocols (e.g. MCP JSON-RPC over standard I/O pipes).
3. **UI Isolation**: Deconstruct UI event loops from core agent processes. UI clients run as independent processes (like Clojure/Babashka `ui-clj` or React dashboards) communicating with the backend orchestration engine over JSON-RPC.

### Benefit
Draws a clear boundary around memory and execution safety, preventing C-extension panics or libraries from crashing the system. Keeps the core orchestration layer extremely lightweight, type-safe, and robust.

---

## 32. Bi-directional JSON-RPC Tool Delegation Pattern

### Intent
Allow out-of-process worker subagents (e.g. Clojure/Babashka workers) to execute stateful or dynamically configured tools owned by the orchestrator process (e.g. Gleam/BEAM core) over a UDS socket.

### Pattern
1. **Dynamic Schema Sync**: The supervisor retrieves all dynamic tool schemas (including MCP and core tools) from the state engine and passes them to the worker in the task initialization envelope.
2. **Worker Interception**: The worker's tool executor checks if a tool is native to the worker. If not, it serializes a JSON-RPC request (`call_tool_on_gleam`) with a unique message ID and sends it back up the UDS stream.
3. **Blocking Socket Read**: The worker blocks its own reader thread, waiting for the JSON-RPC response message with matching ID.
4. **State Actor & Intent Loop Dispatch**: The supervisor receives the request, transacts a delegation datom to SQLite, and broadcasts the event. The reactive `intent_loop` intercepts the datom, executes the tool via the core's dispatch engine (updating agent state/environment), and returns the serialized result back to the worker via UDS.
5. **Resume Worker Execution**: The worker reads the result, unpacks it, and returns the output to the LLM agent loop.

---

## 33. Runtime Decoupled Worker Pattern (Orchestrator-Worker Boundary)

### Intent
Decomplect state management, concurrency scheduling, and side-effect execution by maintaining a strict process and runtime boundary between the orchestrator VM and tool executors.

### Pattern
1. **Functional Orchestrator**: The orchestrator (compiled to Erlang bytecode) handles session state transactions (EAVT datoms), supervisor trees, and external MCP coordination.
2. **Dynamic Scripting Worker**: The worker runtime (e.g. Babashka Native Image) is started dynamically in an isolated OS process via Unix Domain Sockets (UDS) and only evaluates user-defined shell tasks.
3. **Structured Protocol**: The orchestrator and worker communicate strictly via JSON-RPC payloads. All tool requests are serialized, keeping the execution logic completely decoupled.
4. **Independent Failure Recovery**: Any crash in the worker runtime triggers an OTP restart, leaving the orchestrator's state database intact.

---

## 34. Host-Native Kernel Sandbox Pattern (macOS Seatbelt Sandbox)

### Intent
Mitigate system security and crash risks of LLM-generated code by executing scripts inside a strict native OS-level container sandbox using macOS `sandbox-exec`, eliminating external VM interpreters and class-loading overhead.

### Pattern
1. **Declare Sandbox Boundaries**: Define standard paths permitted for read operations and restrict write operations solely to targeted paths (such as `/tmp`, `/private/tmp`, `/var/folders`, and the workspace directory).
2. **Draft Sandbox Scheme Profile**: Construct a macOS Seatbelt sandbox Scheme expression string:
   `(version 1) (deny default) (allow process-fork) (allow process-exec) (allow sysctl-read) (allow file-read*) (allow file-write* (subpath "/tmp") ...)`
3. **Execute via Native Wrapper**: Launch the tool command wrapped under `sandbox-exec -p <profile_string> <command>`, which enforces kernel-level blocking of disallowed operations (e.g. attempting to touch system files outside the paths) and returns stderr/stdout.

---

## 35. State Synchronized In-Memory Datalog Worker Pattern

### Intent
Enable out-of-process scripting workers to run relational Datalog queries natively against the global database state without querying Erlang side-effect API processes.

### Pattern
1. **State Snapshot Fetch**: Query all EAV datoms table from the relational persistence layer (SQLite) inside the supervisor process.
2. **State Serialization**: Serialize all datoms into a compact JSON array and append it as `datoms` parameter to the dynamic JSON-RPC task launch envelope.
3. **Dynamic Schema & Unique Identifier Indexing**: On worker startup, parse facts and rules, dynamically detect reference attribute type maps, transact a unique `:name` identity map, and build an in-memory DataScript database instance.
4. **Local Query Evaluation**: Evaluate Datalog skill rule queries natively using native Clojure syntax, and map integer IDs back to original string identifiers post-query.

---

## 36. Zero-Dependency Micro-Datalog Interpreter Pattern

### Intent
Execute recursive Datalog queries natively in a dynamic scripting runtime (e.g., Babashka) without relying on heavy external JVM libraries like DataScript, avoiding JVM boot overhead and classloading bloat.

### Pattern
1. **Fact Atom**: Store EAV facts in a simple Clojure `atom` referencing an immutable list of tuples.
2. **Variable Resolution**: Parse queries to distinguish logic variables (e.g., `?entity`) from literals.
3. **Unification Algorithm**: Implement a recursive matching function `match-term?` that walks the clauses. If a term is a logic variable, bind its value to an environment map (`env`). If it's bound, compare the values.
4. **Recursive Rule Solving**: For `rule` evaluations, recursively call `solve-clause` to match rule bodies against the fact database, effectively traversing tree structures natively without an external Datalog compiler.

### Benefit
Keeps the runtime completely independent from the JVM ecosystem, resulting in instantaneous boot times, while retaining the functional expressiveness required to reason over complex Datalog graphs and policies.

---

## 37. Threaded Exception Diagnostics in Auto-Healing Loops

### Intent
Log detailed OS and file permission diagnostics upon loop exhaustion to troubleshoot socket or network connection errors.

### Pattern
Instead of a simple decrementing integer loop, construct a recursive loop that carries both the attempt counter and the last caught exception. Upon exceeding maximum attempts, call a diagnostics printer passing the last exception to inspect filesystem metadata (such as target path presence, parent permissions, read/write capabilities).

### Example
```clojure
(defn diagnose-uds-failure [path exception]
  ;; print path details, file presence, parent permissions, and exception class/message
  )

(defn connect-loop [path]
  (loop [attempt 1
         last-exception nil]
    (let [res (try
                (connect-uds path)
                {:ok true}
                (catch Exception e
                  {:error e}))]
      (if (:ok res)
        (do-work)
        (if (< attempt 3)
          (do
            (Thread/sleep 1000)
            (recur (inc attempt) (:error res)))
          (do
            (diagnose-uds-failure path (:error res))
            (System/exit 1)))))))
```

---

## 38. Safe Stream Payload Escaping Pattern

### Intent
Safely serialize dynamic string fields inside manually concatenated JSON payloads sent over newline-delimited UDS socket connections.

### Pattern
Instead of naive search-and-replace, construct a pipeline of positional replaces:
1. Escape backslashes (`\`) first to prevent escaping double quotes.
2. Escape double quotes (`"`).
3. Escape newlines (`\n`) and carriage returns (`\r`) to protect newline message framing.
4. Escape tabs (`\t`).

### Example (Gleam)
```gleam
pub fn escape_json_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}
```

## 39. Graceful Actor Shutdown and Deterministic Exit Coordination Pattern

### Intent
Cleanly terminate background supervisor actors and associated listeners (like UDS sockets) at the end of a test case or process lifespan, preventing leaked file descriptors, port connections, or trailing output prints after execution finishes.

### Pattern
1. **Define a Shutdown Message**: Add a `Shutdown` payload to the actor's message protocol.
2. **Actor Cleanup Implementation**: Inside `handle_message`, when `Shutdown` is received:
   - Close all open sockets (listening sockets and active client connections).
   - Clean up filesystem resources (e.g., `simplifile.delete` the socket file).
   - Stop the actor using `actor.stop()`.
3. **Deterministic Test Coordination**: In the test case:
   - Monitor the actor's Pid using `process.monitor(pid)`.
   - Send the `Shutdown` message to the actor.
   - Wait for the `DOWN` message in a selector with a reasonable timeout.
   - Proceed only after the actor process has completely exited, ensuring no asynchronous teardown runs after the test returns.

### Example (Gleam)
```gleam
pub fn test() {
  let assert Ok(subj) = start_actor()
  let assert Ok(pid) = process.subject_owner(subj)
  let _monitor = process.monitor(pid)
  
  process.send(subj, Shutdown)
  
  let selector = process.new_selector() |> process.select_monitors(fn(d) { d })
  let assert Ok(_) = process.selector_receive(selector, 1000)
}
```

---

## 40. Safe Print Catch-All Wrapper Pattern

### Intent
Safely write diagnostics and logs to standard output in concurrent actor environments without risking process crashes if standard output gets closed or redirected (e.g., due to test process termination).

### Pattern
1. **Define Native Handler**: Create an Erlang/FFI function that wraps standard output writes in a try-catch block.
2. **Expose to Orchestrator**: Declare the external function in Gleam.
3. **Use Universally**: Call this function instead of raw `io.print` / `io.println` for any diagnostic messages.

### Example (Erlang)
```erlang
safe_print(Binary) ->
    try
        io:put_chars(Binary)
    catch
        _:_ -> ok
    end.
```

---

## 41. Dynamic Namespace Partitioning Pattern

### Intent
Segregate task/session states dynamically within a single SQLite database without cross-session data pollution or index bloat.

### Pattern
1. **Construct Namespaces**: Formulate dynamic table names based on unique session/worker IDs (e.g., `datoms_<session_id>`).
2. **Sanitize Identifiers**: Clean session IDs by replacing symbols that SQLite table syntax rejects (such as hyphens `-`) with underscores `_`.
3. **Lazy Schema Generation**: Generate database tables dynamically via `CREATE TABLE IF NOT EXISTS` upon the first query or transaction for a session.
4. **State Snapshot Separation**: Perform transactions against the segregated table while keeping reads consolidated.

---

## 42. Session-Entity State Unification Pattern

### Intent
Expose isolated session context and static global configurations to workers while completely preventing context rot.

### Pattern
1. **Identity Resolution**: Parse the dynamic `session_id` prefix from worker IDs on socket handshakes.
2. **Unified Data Query**: Read session-specific datoms from the partitioned dynamic table, and query global static rules from the fallback global table.
3. **Global Filter Constraint**: Exclude any dynamic session-specific or message-specific entities from the global table using filtering constraints (e.g., `entity NOT LIKE 'session:%' AND entity NOT LIKE 'message:%'`).
4. **Combine and Serialize**: Merge the datasets and serialize them into the worker context payload.

---

## 43. Arity-Insensitive Datalog Clause Matcher Pattern

### Intent
Enable Datalog query engines to safely parse and match query clauses with variable arities (such as 2-element entity-attribute check clauses) without throwing out-of-bounds index errors.

### Pattern
1. **Check Clause Constraints**: Check the number of elements in the clause before performing index-based access.
2. **Inject Wildcard Symbols**: If the clause lacks a value element (e.g., count is 2), automatically assign a wildcard symbol `'_` as the missing match target.
3. **Existential Fact Verification**: During matching, verify that the fact has matching entity and attribute keys, and skip value binding if the target is the wildcard symbol, treating the query clause as an existential check.

---

## 45. AST-Based Query Transpilation and Execution Isolation Pattern

### Intent
Unify Datalog query construction, AST validation, and process execution, preventing process management leaks (temporary files, exit codes, and path resolution) from coupling with business logic.

### Pattern
1. **Represent Query Components as data structures**: Define Query, Rule, and Datom as strong-typed records on the host side.
2. **Decouple Serialization (Transpiler)**: Implement a pure transpiler (`gleamdb_transpiler.gleam`) converting the AST structures into JSON/EDN data.
3. **Encapsulate Process Isolation (Client)**: Implement a single execution runner (`gleamdb_client.gleam`) that handles temporary file generation, subprocess spawning, stdout capturing, and file deletion.
4. **Structured Response Decoder**: Decode output stdout via JSON decoders into structured records rather than doing substring matching on stdout text.

---

## 46. Redirected Diagnostics to Standard Error Pattern

### Intent
Prevent diagnostic prints and traces from polluting structured command-line outputs (stdout) meant for IPC communication.

### Pattern
1. **Standardize stdout for IPC data**: Direct all process output data (e.g. JSON strings) to stdout.
2. **Redirect Tracing/Debug to stderr**: Wrap all diagnostic print statements so they execute under standard error streams (`stderr`). In Clojure, bind `*out*` to `*err*` during printing: `(binding [*out* *err*] (println ...))`.
3. **Safe Parsing**: Decoders on the host side can now safely parse standard output as clean JSON without needing to strip out debug text.

---

## 47. Index-Driven Datalog Pattern Matching

### Intent
Replace linear O(N) fact scans in Datalog query evaluation with index-driven O(1) lookups, ported from aarondb's EAVT/AEVT/AVET indexing architecture.

### Pattern
1. **Single-Pass Index Build**: On database initialization, run a single `reduce` over all `[e a v]` triples to construct three complementary hash-map indexes:
   - `EAV {entity → {attr → #{values}}}` — primary entity lookup
   - `AVE {attr → {value → #{entities}}}` — reverse value lookup
   - `AEV {attr → {entity → #{values}}}` — attribute-first scan
2. **Selectivity-Driven Lookup**: At query time, `index-lookup` inspects which pattern positions are bound (ground) after resolving variables through the binding environment, then selects the most selective index:
   - Both entity+attr bound → EAV (O(1) set membership or iteration)
   - Attr+value bound → AVE (O(1))
   - Attr-only bound → AEV (O(entities for that attr))
   - Entity-only bound → EAV (O(attrs for that entity))
   - Nothing bound → full-scan fallback
3. **Clean Unification Layer**: Separate `variable?` predicate, `resolve-term` (chase bindings), and `unify` (extend or reject) as distinct, composable functions.
4. **Index Rebuild on Mutation**: After `transact_datalog`, rebuild indexes from the complete fact set to maintain consistency without incremental update bugs.

### Example (Clojure)
```clojure
;; Build indexes in O(N)
(defn build-indexes [facts]
  (reduce
   (fn [{:keys [eav ave aev] :as acc} [e a v]]
     (-> acc
         (assoc-in [:eav e a] (conj (get-in eav [e a] #{}) v))
         (assoc-in [:ave a v] (conj (get-in ave [a v] #{}) e))
         (assoc-in [:aev a e] (conj (get-in aev [a e] #{}) v))))
   {:eav {} :ave {} :aev {} :facts facts}
   facts))

;; Select index at query time
(defn index-lookup [db pe pa pv env]
  (let [re (resolve-term pe env)
        ra (resolve-term pa env)
        e-bound? (not (variable? re))
        a-bound? (not (variable? ra))]
    (cond
      (and e-bound? a-bound?) (get-in (:eav db) [re ra])  ;; O(1)
      (and a-bound? v-bound?) (get-in (:ave db) [ra rv])  ;; O(1)
      a-bound?                (get (:aev db) ra)           ;; O(entities)
      :else                   (:facts db))))               ;; O(N) fallback
```

---

## 48. Cost-Based Selectivity Heuristic for Clause Reordering

### Intent
Prevent worst-case query times by automatically ordering join and match clauses so that the most selective (highly bound) clauses execute first.

### Pattern
1. **Clause Variable Analysis**: Implement `clause-vars` to extract all variable symbols (`?x`) present in a clause.
2. **Selectivity Score Function**: Map each clause to a cost integer based on current variable grounding:
   - Grounded constants or bound variables = Low Cost (1 to 10)
   - Partially bound rule/graph clauses = Medium Cost (100 to 500)
   - Unbound positive triples = High Cost (1000)
   - Unbound filters or negative clauses = Extremely High Cost (5000 to 8000) to force deferral.
3. **Greedy Reordering**: Perform a greedy selection loop. In each iteration, select the clause with the minimum cost given the current set of bound variables, append it to the planned queue, and union its variables into the bound set.

### Example (Clojure)
```clojure
(defn reorder-clauses [clauses bound-vars]
  (loop [remaining clauses
         bound bound-vars
         acc []]
    (if (empty? remaining)
      acc
      (let [best (apply min-key #(estimate-cost % bound) remaining)
            next-remaining (remove #(= % best) remaining)
            new-bound (clojure.set/union bound (clause-vars best))]
        (recur next-remaining new-bound (conj acc best))))))
```

---

## 49. Negation-as-Failure and Deferrable Filter Expression Evaluator

### Intent
Incorporate non-monotonic logic (negation) and dynamic comparisons (filters) into Datalog while preventing issues with unbound variables.

### Pattern
1. **Dynamic Predicate Dispatch**: Extend `solve-clause` to differentiate between positive facts, negative constraints (`not` clauses), and boolean filters.
2. **NAF Pruning**: Evaluate a `not` clause by executing its inner pattern against the database under the current environment. If it returns any valid bindings, reject (prune) the current environment; otherwise, pass the current environment through.
3. **Deferred Filter Evaluation**: Evaluate inequality predicates (e.g. `(> ?a 25)`) dynamically. If any variable in the expression is unbound, throw an error. This is guarded by the cost planner, which ensures filters only run after their variables are grounded.

---

## 50. Grouped Projections for Aggregate Query Execution

### Intent
Compute aggregate statistics (`count`, `sum`, `min`, `max`, `avg`, `median`) over Datalog find variables while grouping by non-aggregated variables.

### Pattern
1. **Syntax Detection**: Parse the `:find` vector to separate aggregate symbols (e.g., `(count ?e)`) from standard variables.
2. **Grouping Phase**: Group all unified environment bindings using the values of the non-aggregated variables as the key: `(group-by (fn [env] (mapv #(resolve-term % env) group-keys)) envs)`.
3. **Aggregate Reducer**: For each group, extract the values of the target variable from all matching environments, apply the corresponding reducer function, and project the final aggregated vector.

---

## 51. Normalized Rank Fusion (Weighted Union)

### Intent
Combine result sets from different search modalities (e.g. TF-IDF and vector similarity) using customizable weights and scale-free normalization.

### Pattern
1. **Strategized Min-Max Scaling**: Define a normalization step that maps raw scores to `[0.0, 1.0]`. Guard against zero division when all scores are equal by using a default safety range (`1.0`).
2. **Union Score Accumulation**: Extract the set of all unique entities across both results. For each entity, fetch the normalized score from each list (defaulting to `0.0` if absent), apply the respective weights, and sum them.
3. **Deterministic Ranking**: Sort the resulting entity list in descending order of weighted scores.

---

## 52. Multi-Graph Algorithm Dispatch in Datalog Engine

### Intent
Enable advanced graph traversal and analysis (Shortest Path, Reachable nodes, Cycle Detection, Kahn's Topological Sort, PageRank, Tarjan's SCC) as composable Datalog clauses.

### Pattern
1. **Graph Construction from Triples**: Construct a directed adjacency graph representation on-the-fly using the database's attribute index (`AEV` index): `(get-in db [:aev edge] {})`.
2. **DFS/BFS Traversal Adapters**: Implement native graph algorithms (Tarjan's SCC, BFS shortest path, PageRank iteration) using Clojure collections, avoiding external libraries or Java class imports.
3. **Unified Unification Output**: Map graph algorithm results back to unified bindings. For example, `shortest-path` yields path vectors and costs, unifying them with variables in the pattern.

---

## 53. SCI-Compliant Bloom Filter Representation

### Intent
Implement a space-efficient set membership checker that runs successfully inside Babashka's restricted SCI sandbox without classpath or sandbox-exec errors.

### Pattern
1. **Class-Free Representation**: Instead of using `java.util.BitSet` (which is typically blocked in SCI sandboxes), model the active bit array using a standard Clojure persistent set (`#{}`).
2. **Hash Index Generation**: Compute `k` hash indices for a given key by salting the key with a range sequence and taking the absolute value modulo the filter size.
3. **Membership Check**: Check if the set of computed hash indices is a subset of the active bit set.

---

## 54. Boundary Type Coercion for Heterogeneous JSON-to-EDN Transpilation

### Intent
Maintain strict Datalog symbolic semantics when serializing AST queries from a statically-typed language (Gleam) to an untyped dynamic scripting interpreter (Clojure/Babashka) over standard JSON streams, preventing string vs. symbol equality mismatch failures.

### Pattern
1. **Typed AST Representation**: Define Datalog query components (Triples, Filters, Negations, and Graph queries) as strongly-typed union variants on the host side.
2. **JSON Array Serialization**: Serialize host variants into structured JSON arrays (e.g. `["not", ["?e", "blocked", "true"]]` or `[[">", "?a", 25]]`).
3. **Postwalk Symbol Coercion**: In the client worker, walk the parsed JSON structure using `walk/postwalk` and convert known operators and variable strings (starting with `?`) to symbols. This ensures standard Clojure pattern matching and unification works seamlessly.

### Example (Clojure)
```clojure
(defn parse-clause-helper [c all-rule-attrs]
  (let [c (walk/postwalk
           (fn [x]
             (cond
               (and (string? x) (contains? #{"not" "shortest-path" ">" "<"} x)) (symbol x)
               (and (string? x) (clojure.string/starts-with? x "?")) (symbol x)
               :else x))
           c)]
    ;; ... proceed with standard symbol matching ...
    ))
```

---

## 55. Environment-to-Config Model Alignment Pattern

### Intent
Ensure consistent model configuration across multi-runtime applications (e.g., Python agent CLI, Gleam/BEAM backend) by aligning process-level environment overrides and static configuration files, avoiding routing mismatches or fallback discrepancies.

### Pattern
1. **Define Source of Truth**: Map the primary execution models dynamically. If process-level overrides (such as `HERMES_MODEL`) are present, they take precedence but must align exactly with the default values specified in the static configuration (`config.yaml`).
2. **Synchronize Overrides**: Update environment configuration scripts/files (`.env`) and static configuration declarations (`config.yaml`) to reference the identical canonical model ID (`deepseek/deepseek-v4-flash`), avoiding hybrid execution states where different system boundaries make calls to mismatched endpoints.
3. **Validate Fallbacks**: Align primary, fallback, and auxiliary keys concurrently to prevent the application from degrading to a low-performance or mismatched model type during error recovery.

---

## 56. Isolated Worker Output Verification Pattern

### Intent
Ensure test validation suites can correctly identify and verify output files generated by subagents executing in directories distinct from the repository root.

### Pattern
1. **Identify Executing CWD**: Determine the working directory under which the subagent processes are launched (e.g., `babashka_workers/`).
2. **Resolve Verification Target Paths**: When defining the list of files to check, prefix them with the subagent's directory path (e.g. `babashka_workers/headers.txt`) to locate the outputs accurately.
3. **Absolute Link Construction**: Use the fully-resolved paths when generating markdown or HTML reports to construct correct clickable file URLs (e.g. `file:///absolute/path/to/project/babashka_workers/headers.txt`).
4. **Targeted Teardown**: Ensure the cleanup phase clears the target files from the correct sub-directory before test execution begins.




## 57. Decoupled Context-Execution Prompting Pattern

### Context
When orchestrating multi-agent or out-of-process workers, execution is often split into a planning/reasoning phase followed by an execution (tool-calling) phase.

### Problem
System prompts intended solely for the planning phase (e.g. constraints like "Return ONLY the reasoning chain") pollute the execution phase's message history if left in. This causes models to refuse to call tools or output token noise (e.g. `" P-->"`).

### Pattern
1. Define a separate `planning-system-prompt`.
2. Perform the planning turn using `[user-prompt planning-system-prompt]`.
3. Extract the `planning-response` (assistant message).
4. For the subsequent execution loop, initialize the history using `[user-prompt planning-response]`, explicitly omitting `planning-system-prompt` from the context history. This allows the model to respond to tools without the planning-only constraints.

### Example
(let [reasoning-prompt {:role "system" :content "Return ONLY the chain of thought."}
      reasoning-msg (generate-reasoning messages reasoning-prompt)]
  ;; Decouple system constraints from tool execution loop
  (loop [loop-messages (vec (concat messages [reasoning-msg]))]
    (let [response (generate-completion loop-messages tools)]
      ...)))
```

---

## 58. Key-Restricted Robust JSON/EDN Healing Parser Pattern

### Context
When parsing JSON arguments generated by LLMs in tool execution backends, the payload can be malformed (e.g., missing commas, escaped nested quotes, unquoted keys, single quotes). This is particularly common when serialization targets complex data types like nested lists or Datalog facts.

### Problem
Naive JSON string repair (like replacing all `\"` with `"`) can break valid JSON values (e.g., escaping within queries or user content). Simply falling back to an EDN reader globally can cause collisions on variables (e.g., `x :where` matching a key replacement pattern and converting to keyword `:xwhere`).

### Pattern
1. **Standard Try-Catch**: Attempt standard JSON parsing first.
2. **Selective Nested Value Healing**: If standard parsing fails, identify target arrays (e.g., `inputs` or `facts`) using regex, and clean their contents by replacing any sequence of backslashes and quotes with a single quote.
3. **Key-Restricted EDN Conversion**: Convert only *known* schema keys (e.g., `query`, `inputs`, `facts`, etc.) to EDN keyword syntax (e.g. `:query`), preserving spaces.
4. **EDN Fallback**: Read the cleaned string using a standard EDN reader, which naturally supports space-separated vectors and missing commas.

### Example
```clojure
(defn parse-robust-json [s]
  (try
    (json/parse-string s true)
    (catch Exception _
      (try
        (let [cleaned (clojure.string/replace s #"(?:\"|')?(inputs|facts)(?:\"|')?\s*:\s*(\[[\s\S]*\])"
                                              (fn [[_ key-val inputs-val]]
                                                (str "\"" key-val "\": " (clojure.string/replace inputs-val #"[\\\\\"]+" "\""))))
              edn-str (-> cleaned
                          (clojure.string/replace #"(?:\"|')?(command|path|content|url|code|image|query|inputs|facts)(?:\"|')?\s*:" ":$1")
                          (clojure.string/replace #",\s*" " "))
              edn-val (edn/read-string edn-str)]
          (walk/keywordize-keys edn-val))
        (catch Exception e
          (throw (Exception. (str "JSON/EDN parsing failed: " (.getMessage e) " for string: " s))))))))
```

---

## 59. Clean State Testing Pattern (Database Reset)

### Context
In agentic testing suites, agents persist their conversation state, session parameters, and working directory information to a local session database (such as SQLite) for checkpointing and resuming capability.

### Problem
When running automated tests iteratively, deleting the generated file outputs in the workspace without deleting the session database causes subsequent test runs to fail. The agent will boot, restore its session state from the database, see that the task is "already completed," and output a false-positive summary without executing any tools or generating the actual workspace files.

### Pattern
To guarantee clean, reproducible, and correct test runs, the test runner must:
1. **Reset Database**: Proactively delete the agent's SQLite session database file (e.g., `~/.hermes/state.db`) at the start of the execution.
2. **Purge Logs**: Clear any previous run logs (e.g., `dogfood_outputs/`) to avoid old log state leakage.
3. **Re-execute**: Execute the agent from a zero-state baseline, forcing all tools to run from scratch.

### Example
```clojure
(defn clean-old-files []
  (println "Cleaning old output files...")
  (doseq [{:keys [file]} output-files]
    (when (fs/exists? file)
      (fs/delete file)
      (println "Deleted:" file)))
  (let [db-file (io/file (System/getProperty "user.home") ".hermes" "state.db")]
    (when (.exists db-file)
      (.delete db-file)
      (println "Deleted agent session database: state.db")))
  (let [outputs-dir (io/file "dogfood_outputs")]
    (when (.exists outputs-dir)
      (doseq [f (.listFiles outputs-dir)]
        (.delete f))
      (println "Cleaned dogfood_outputs/ directory"))))

---

## 60. Dynamic Sandboxing and Relative Root Paths Pattern

### Context
When running agentic code execution engines in multi-user or distributed environments, tools execute shell tasks under strict sandboxing profiles (such as macOS `sandbox-exec`) or invoke sibling tools using file-based arguments.

### Problem
Hardcoding local developer directory paths (e.g. `/Users/moe/Desktop/ayncoder`) inside sandbox allow-lists or path resolution fallbacks breaks execution when the application is deployed or run on any other user's machine, causing execution to fail or run with incorrect write/read permissions.

### Pattern
1. **Dynamic Workspace Allowed Paths**: In sandbox configuration lists, resolve the execution directory dynamically at runtime (e.g., using `(System/getProperty "user.dir")` in JVM/Clojure) rather than using hardcoded literals.
2. **Relative Root Path Fallbacks**: When recovering or falling back during directory resolution failures, fall back to relative indicators like `"."` rather than absolute developer paths. This allows the process to execute relative to the launcher environment.

### Example
```clojure
;; babashka_workers/src/worker.clj
(let [default-paths ["/tmp" "/private/tmp" "/var/folders" (System/getProperty "user.dir")]
      all-paths (distinct (concat default-paths custom-paths))]
  ...)
```
```gleam
// hermes_beam/src/gleamdb_client.gleam
let root_dir = case utils.get_cwd() {
  Ok(cwd) -> {
    case string.ends_with(cwd, "/hermes_beam") {
      True -> string.drop_end(cwd, 12)
      False -> cwd
    }
  }
  Error(_) -> "."
}
```

---

## 31. OTP Process Name Registration and static_supervisor Worker Supervision

### Context
When running multiple stateful or long-running service actors (such as state databases, network listeners, and circuit breakers) on Erlang/Gleam, using direct PIDs or subjects makes it impossible to automatically restart actors on crash without breaking down communications inside client/agent loop processes.

### Pattern
1. **Name Registration**: Create process names using `process.new_name("name")`.
2. **Named Actor Startup**: In the worker's start function, register the actor name dynamically via `actor.named` before calling `actor.start`.
3. **Supervised Tree Initialization**: Define a `static_supervisor` and add workers using `supervision.worker` functions wrapping the supervised start functions.
4. **Dynamic Address Resolution**: Construct a named subject handle using `process.named_subject(name)`. Client code queries/transacts messages through the named subject rather than absolute PIDs.

### Example
```gleam
pub fn run_app() {
  let db_name = process.new_name("db_actor")
  let db_subj = process.named_subject(db_name)

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForAll)
    |> static_supervisor.add(supervision.worker(fn() {
         db_actor.start_supervised(db_name, conn)
       }))
    |> static_supervisor.start()

  let db = db_actor.from_subject(db_subj)
  // Calls now resolve to the active instance automatically
  db_actor.query(db, "...")
}

## 32. TCP Socket Port Lock Pattern (Single-Instance Guard)

### Context
When running network listener daemons (such as Telegram updates poller, WebSocket receivers, or message brokers), running multiple concurrent instances of the same daemon results in message collisions, split-brain states, and message stealing. We need a way to enforce a single running instance across the host system.

### Problem
Physical file locks (lockfiles) on disk are fragile. If the process crashes or is killed abruptly (`kill -9`), the lockfile remains on disk. Subsequent boots will read the stale lockfile and falsely assume another process is running, blocking the self-healing restart loop.

### Pattern
1. **Allocate dedicated port**: Select a dedicated TCP port (e.g. `8555`) to act as the guard lock.
2. **Listen without address reuse**: Open a listening TCP socket on that port with `{reuseaddr, false}` (or equivalents).
3. **Handle Errors**: If binding succeeds, keep the socket open for the lifetime of the process. If it fails (e.g. `eaddrinuse`), exit gracefully immediately.
4. **Kernel Cleanup**: The operating system kernel automatically cleans up and releases the socket resource when the process terminates (under any exit or crash condition), ensuring the lock is immediately available for the restarted process.

### Example
```erlang
%% hermes_http.erl
acquire_port_lock(Port) ->
    case gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, false}]) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.
```
```gleam
// hermes_beam.gleam
pub fn main() {
  case acquire_port_lock(8555) {
    Ok(_socket) -> {
      // Start polling loop...
      process.sleep_forever()
    }
    Error(_) -> {
      io.println("Error: Port in use. Another instance is running.")
      Nil
    }
  }
}
```

## 33. Monitored Asynchronous Task Supervision Pattern (`taskle`)

### Context
When executing asynchronous worker computations (such as message routing, network requests, or long-running computations) on the BEAM, launching them via unlinked, unmonitored processes can lead to resource leaks if tasks hang forever, or silent failures if they crash. We need a way to spawn tasks asynchronously, enforce a safety timeout, and trap crashes without blocking the main event/polling loop.

### Problem
Directly awaiting a concurrent task inside the main polling loop blocks subsequent events. However, spawning bare unmonitored processes hides errors. We want to run processes concurrently but still monitor their outcomes.

### Pattern
1. **Spawn Monitored Task**: Use `taskle.async` to launch the async computation, yielding a `Task(t)` handle.
2. **Spawn Asynchronous Supervisor**: Spawn a separate, lightweight monitor process (`process.spawn`) so that the main execution/polling loop remains unblocked.
3. **Await with Timeout**: In the monitor process, call `taskle.await(task, TimeoutMs)`.
4. **Reclaim on Timeout**: If `Error(Timeout)` occurs, call `taskle.cancel` to kill the task process and reclaim resources.
5. **Trap Crashes**: If `Error(Crashed(reason))` is returned, log or record the failure gracefully.

### Example
```gleam
import taskle
import gleam/erlang/process

pub fn dispatch_work(items: List(WorkItem)) {
  list.each(items, fn(item) {
    let task = taskle.async(fn() {
      perform_computation(item)
    })

    process.spawn(fn() {
      case taskle.await(task, 60_000) {
        Ok(res) -> handle_success(res)
        Error(taskle.Timeout) -> {
          let _ = taskle.cancel(task)
          log_timeout(item)
        }
        Error(taskle.Crashed(reason)) -> {
          log_crash(item, reason)
        }
        _ -> Nil
      }
    })
  })
}
```

## 34. Hybrid Third-Party API FFI Adapter Pattern (`telega`)

### Context
When integrating complex third-party API clients or SDKs (like `telega`) in Gleam, they often expect an HTTP client adapter package (e.g. `telega_httpc` or `telega_hackney`) to compile and dispatch requests. If we want to use the library's type-safe parameters, encoders/decoders, and API helpers without adding heavy/transitive Erlang dependencies, we need a way to adapter-bind the client to our existing custom FFI network functions.

### Problem
Third-party clients require implementing a spec-compliant fetch adapter function matching their `FetchClient` type, translating generic HTTP requests to generic HTTP responses.

### Pattern
1. **Define Fetch Adapter**: Write a function that maps the third-party framework's `Request(String)` to the custom Erlang HTTP client FFI.
2. **Support HTTP Methods**: Match on the request method (`http.Get` or `http.Post`). Extract headers (like `Content-Type`) and body.
3. **Map Results**: Map successful payloads to standard `Response(String)` and network errors to the third-party client's custom error type.
4. **Instantiate Client**: Pass this local fetch adapter to the library client factory function.

### Example
```gleam
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/uri
import telega/client
import telega/api
import telega/error.{type TelegaError, FetchError}

pub fn http_fetch_client(req: Request(String)) -> Result(Response(String), TelegaError) {
  let url = request.to_uri(req) |> uri.to_string
  case req.method {
    http.Get -> {
      case get_request(url) {
        Ok(body) -> Ok(Response(status: 200, headers: [], body: body))
        Error(err) -> Error(FetchError(string.inspect(err)))
      }
    }
    http.Post -> {
      let content_type =
        list.find(req.headers, fn(h) { string.lowercase(h.0) == "content-type" })
        |> result.map(fn(h) { h.1 })
        |> result.unwrap("application/json")
      case post_request(url, req.headers, content_type, req.body) {
        Ok(body) -> Ok(Response(status: 200, headers: [], body: body))
        Error(err) -> Error(FetchError(string.inspect(err)))
      }
    }
    _ -> Error(FetchError("Unsupported method"))
  }
}
```


```

## 35. Supervised Third-Party Bot & Dynamic Chat Supervisor Pattern (`telega`)

### Context
When constructing high-reliability chatbot integrations (like Telegram Bot API) on the BEAM, we want each chat session to be isolated. If a user's agent execution crashes or hangs, it should not affect other conversations. Additionally, messages sent by a single user must be processed sequentially to maintain conversational consistency, while processing across different users runs concurrently.

### Problem
Stateless updates-polling loops spawn parallel tasks for all updates indiscriminately. This can execute user messages out-of-order and lacks dynamic lifecycle fault tolerance.

### Pattern
1. **Define Handler Closure**: Create a factory function (`make_text_handler`) that wraps the agent callback.
2. **Sequential Blocking via Task Await**: Inside the text handler, spawn agent execution inside `taskle.async` but block the chat actor process sequentially using `taskle.await` with a safety timeout, trapping crashes cleanly so the session actor survives.
3. **Instantiate Supervised Router & Bot**: Set up a `router` using the library helper and apply it to a supervised bot config.
4. **Link to System Supervisor**: Start the poller via the dynamic supervisor tree builder (`init_for_polling_nil_session`) and return the root supervisor's Pid.

### Example
```gleam
pub fn make_text_handler(
  run_agent: fn(String, String) -> String,
) -> fn(
  bot.Context(Nil, error.TelegaError),
  String,
) -> Result(bot.Context(Nil, error.TelegaError), error.TelegaError) {
  fn(ctx: bot.Context(Nil, error.TelegaError), text: String) {
    let session_id = "tg_" <> ctx.key

    let task =
      taskle.async(fn() {
        send_typing(ctx.config.api_client, ctx.key)
        let reply_str = run_agent(text, session_id)
        let _ = reply.with_text(ctx, reply_str)
        Nil
      })

    case taskle.await(task, 180_000) {
      Ok(Nil) -> Ok(ctx)
      Error(taskle.Timeout) -> {
        let _ = taskle.cancel(task)
        let _ = reply.with_text(ctx, "Request timed out.")
        Ok(ctx)
      }
      Error(_) -> {
        let _ = reply.with_text(ctx, "An internal error occurred.")
        Ok(ctx)
      }
    }
  }
}

pub fn start(
  token: String,
  run_agent: fn(String, String) -> String,
) -> process.Pid {
  let api_client = client.new(token, http_fetch_client)

  let r =
    router.new("hermes_router")
    |> router.on_any_text(make_text_handler(run_agent))

  let assert Ok(bot) =
    telega.new_for_polling(api_client)
    |> telega.with_router(r)
    |> telega.init_for_polling_nil_session()

  telega.get_supervisor_pid(bot)
}
```

---

## 36. Persistent Namespace Sandbox Pattern (Clojure/Babashka worker.clj)

### Context
When executing dynamic Clojure/Babashka scripting tools (like `bb_eval`) inside an autonomous agent daemon, starting a fresh JVM/Babashka process for each evaluation is slow and stateless, discarding function definitions and required namespaces.

### Problem
Subprocess-based evaluation prevents incremental agent programming (compiling functions in turn 1 and reusing them in turn 2) and has a high execution startup cost.

### Pattern
1. Create a dedicated namespace dynamically using `create-ns 'sandbox-user`.
2. Refer standard core libraries using `(binding [*ns* (find-ns 'sandbox-user)] (refer 'clojure.core))`.
3. Wrap evaluation in `binding [*out* sw *err* se *ns* (find-ns 'sandbox-user)] (load-string code)` to capture output and execute within the sandbox namespace.

### Benefit
Provides extremely fast, stateful evaluation during a single worker process lifetime, enabling true REPL-driven agent capabilities.

---

## 37. Stateful OTP Actor Timer & Asynchronous Spawn Pattern (Gleam)

### Context
When running scheduled automations inside a strictly functional BEAM agent ecosystem, the scheduler must manage time check ticks and trigger heavy task operations without blocking its incoming mailbox or causing duplicate/overlapping execution ticks.

### Problem
Using simple blocking loops (`process.sleep`) inside an actor block stops the actor from receiving client messages (`AddJob`, `RemoveJob`). Conversely, spawning execution blocking loops directly inside the tick handler blocks the actor thread, delaying subsequent scheduler ticks.

### Pattern
1. **Self-Scheduled Ticks**: Use `actor.new_with_initialiser` to retrieve the actor's own `Subject(Message)`. On initialization and at the end of each `Tick` handler, schedule the next tick asynchronously using `process.send_after(self_subject, interval_ms, Tick)`.
2. **Double-Trigger Prevention**: Record a minute-resolution Gregorian timestamp `current_minute_secs = calendar:datetime_to_gregorian_seconds(...)` when a job executes. If the schedule matches again during the same minute, verify `job.last_run == Some(current_minute_secs)` to skip execution.
3. **Asynchronous Spawning**: Spawn execution runs inside an isolated process (`process.spawn`) so that network overhead or model reasoning times do not block the scheduler actor's tick interval.

### Example
```gleam
pub fn start(db_conn: StateActor) -> Result(CronScheduler, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subj) {
    let _timer = process.send_after(subj, 5000, Tick)
    let selector = process.new_selector() |> process.select(subj)
    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(subj)
    |> Ok
  })
}
```

### Benefit
Guarantees strict scheduling correctness, avoids deadlocks, and keeps the scheduler responsive to dynamic API calls while executing heavy LLM workloads in the background.

---

## 38. Native Dialectic Graph Contradiction & Vector Integration Pattern (GleamDB)

### Context
Autonomous agents need memory representation systems that handle entity graphs, preference modeling, and search over historical interactions without delegating sensitive user data to SaaS APIs (Honcho, mem0, Supermemory).

### Problem
External integrations introduce security risks, network dependency failures, and API keys. Doing this natively requires implementing graph queries, contradiction detection, and semantic vector similarity inside a local Datalog database.

### Pattern
1. **Fact Representation**: Store facts, preferences, and traits as Triple datoms `[Entity, Attribute, Value]` (e.g. `["user:default", "profile/editor", "VS Code"]`) inside the local SQLite database.
2. **Deterministic Contradiction Finding**: Query contradictions using Datalog inequality rules:
   ```clojure
   [:find ?attr ?v1 ?v2
    :where
    [user:default ?attr ?v1]
    [user:default ?attr ?v2]
    [[!= ?v1 ?v2]]]
   ```
3. **Local Vector Search**: Store embedding vectors inside a dedicated SQLite table and run cosine similarity calculations in pure Gleam/BEAM logic, mapping queries to the top-$k$ nearest sessions.
4. **Interactive Reconciliation**: When contradictions are returned, trigger agent-level dialogue or delete the obsolete fact in favor of the newly transacted fact to keep user records consistent.

### Benefit
Guarantees absolute privacy, reduces network round-trips to zero, and allows highly complex graph queries to execute locally under OTP supervisors.

---

## 39. Session-Exit Curator Hook Pattern (Autonomous Learning)

### Context
AI agents that learn dynamically should compile successful patterns into reusable skills (such as instructions, rules, and datoms) to optimize future session runs without cluttering user context or adding prompt overhead.

### Problem
Executing LLM-based skill curation synchronously inside the conversation loop adds significant response latency. Conversely, ignoring history after the session exits discards valuable context.

### Pattern
1. Accumulate message history strings inside the `AgentState` record during the session's active turns.
2. Hook into session exit hooks (such as `/quit` or `/exit` command handlers or dynamic shutdown triggers).
3. Reverse the history list to restore the chronological flow of conversation: `list.reverse(state.agent_state.history)`.
4. Asynchronously invoke the curator model (`curator.synthesize_skill`) using the chronological transcript to extract reusable patterns and serialize them to the local `skills/` directory.

### Benefit
Isolates cognitive curation from real-time response generation, maintaining fast conversation response times while enabling persistent, autonomous learning across sessions.

---

## 40. JVM-Free Dependency Vendoring & Task Integration Pattern (Babashka)

### Context
When developing Clojure/Babashka workers designed for 100% JVM-Free native execution (e.g. inside Docker or resource-constrained developer setups), declaring dynamic external dependencies (`:deps`) in `bb.edn` forces Babashka to spawn a JVM-based dependency resolver. This breaks portability on machines lacking a JDK/JRE runtime.

### Problem
Runtime dependency resolution complects program execution with package fetching and requires a heavy Java Runtime Environment (JRE/JDK) to parse Maven or Git trees, defeating the speed and simplicity of standalone native binaries.

### Pattern
1. **Source Vendoring**: Download the raw `.clj` source files of third-party libraries (e.g. `babashka/nrepl-client` and `nextdoc/ai-tools`) directly into folders within the local `src/` hierarchy (e.g., `src/babashka/`, `src/io/nextdoc/`).
2. **Local Classpath Resolution**: Ensure the `bb.edn` paths include the vendored directories: `{:paths ["src" "test"]}`.
3. **Dynamic Task Registration**: Declare CLI tasks in `bb.edn` that require the local namespaces directly, removing the `:deps` map completely:
   ```clojure
   :tasks
   {nrepl:test {:requires [[io.nextdoc.tools :as tools]]
                :task (System/exit (tools/run-tests-task *command-line-args*))}}
   ```

### Benefit
Allows complex external utility frameworks and nREPL connection setups to execute with sub-10ms startup latency entirely within the standalone native Babashka binary, achieving zero external JRE/JDK runtime dependencies.

---

## 41. Stdio-to-Socket Relay Bridge Pattern (MCP)

### Context
When integrating agents with graphical IDE extensions (such as VS Code's Calva Backseat Driver), the extension publishes its capabilities via a local TCP socket server. Standard agent frameworks (like Model Context Protocol) require stdio processes.

### Problem
Directly connecting standard stdio-bound agents to editor-bound TCP socket ports is impossible without a local proxy or relay script.

### Pattern
1. **Find Port Dynamically**: Look up the socket port from the designated IDE state directory (e.g. `<workspace>/.calva/mcp-server/port`).
2. **Setup Socket Connection**: Open a TCP Socket to `127.0.0.1` using the parsed port.
3. **Asynchronous Bidirectional Piping**: Spawn two concurrent threads or futures (in Clojure, using `future`) to pipe input streams to output streams:
   * Thread 1: Read from standard input (`System/in`) and write to socket output.
   * Thread 2: Read from socket input and write to standard output (`System/out`).
4. **Clean Shutdown**: Wrap streams in `with-open` so that if either stream hits EOF or throws an exception, all resources close cleanly.

### Example
```clojure
(defn- pipe [^InputStream in ^OutputStream out]
  (let [buffer (byte-array 4096)]
    (try
      (loop []
        (let [n (.read in buffer)]
          (when (pos? n)
            (.write out buffer 0 n)
            (.flush out)
            (recur))))
      (catch Exception _ nil))))

(defn start-bridge [port]
  (with-open [socket (Socket. "127.0.0.1" port)
              sin (.getInputStream socket)
              sout (.getOutputStream socket)]
    (let [t1 (future (pipe System/in sout))
          t2 (future (pipe sin System/out))]
      @t1
      @t2)))
```

### Benefit
Allows standard Stdio-based AI agent hosts to interact seamlessly with socket-based IDE extension servers, enabling visual editor evaluations and AST-safe edits.

---

## 42. Explicit Learning Log Pattern (Model-Agnostic Coding Taste)

### Context
When building autonomous coding agents that adapt to the developer's coding styles, choices, and corrections, the agent needs a persistent preference representation.

### Problem
Implicit neuro-symbolic taste profiles are opaque, proprietary, and complected with the AI model weights and synchronization server lifecycles, causing lock-in and auditability challenges.

### Pattern
1. **Explicit Data Representation**: Record style guidelines, framework rules, bug resolutions, and patterns inside standard Markdown files (`learnings.md` and `patterns.md`) located in the root of the workspace.
2. **Standard Git Versioning**: Save and version the logs directly in the project repository using standard Git commands. This makes preferences portable and shareable with team members out-of-the-box without requiring special sync tools.
3. **Structured Entry Synthesis**: At the end of a coding session, task the agent with analyzing the execution transcript and compiling key lessons into new log entries following a strict format (Problem -> Resolution -> Impact).
4. **Context Injection**: Require the agent to read these log files at the start of a session to dynamically shape its behavior according to the project's coding style.

### Benefit
Guarantees absolute transparency and human-editability of agent preferences, ensures 100% model agnosticism, and enables teams to track style evolution using standard version control histories.


