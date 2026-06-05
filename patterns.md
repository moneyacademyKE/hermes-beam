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


