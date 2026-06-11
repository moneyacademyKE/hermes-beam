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


