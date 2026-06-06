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
