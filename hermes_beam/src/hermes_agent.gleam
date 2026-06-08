import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import hermes_client.{type LineParserState, StreamChunk, StreamEnd, StreamError, StreamStart, StreamTimeout}
import hermes_exec
import iteration_budget
import state_actor.{type StateActor}
import mcp_client
import constants
import model_router.{type ModelRouter}
import error_classifier

// ─── Tool Schemas ─────────────────────────────────────────────────────────────
// Static OpenAI-format tool schemas exposed to the LLM.

pub const run_command_schema = "{\"type\":\"function\",\"function\":{\"name\":\"run_command\",\"description\":\"Execute a shell command in the sandboxed terminal environment and return its stdout/stderr output and exit code. CRITICAL: You MUST use Babashka (bb) for any task that requires scripting. DO NOT USE PYTHON.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"The shell command to run (e.g. \\\"ls -la\\\", \\\"cat README.md\\\", \\\"echo hello\\\", \\\"bb -e '(+ 1 2)'\\\").\"}},\"required\":[\"command\"]}}}"

pub const write_file_schema = "{\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"description\":\"Write content to a file at the given path.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Absolute or relative path to the file to write.\"},\"content\":{\"type\":\"string\",\"description\":\"The text content to write to the file.\"}},\"required\":[\"path\",\"content\"]}}}"

pub const read_file_schema = "{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read the contents of a file at the given path. Returns the file text on success or an error message.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Absolute or relative path to the file to read.\"}},\"required\":[\"path\"]}}}"

// ─── Core Types ────────────────────────────────────────────────────────────────

pub type AgentEvent {
  MessageDelta(content: String)
  ToolStart(name: String, arguments: String)
  ToolComplete(name: String, result: String)
  MessageComplete(content: String)
}

pub type AgentState {
  AgentState(
    session_id: String,
    model: String,
    cwd: String,
    /// OpenAI-format message history as pre-encoded JSON strings
    history: List(String),
    db_conn: StateActor,
    exec_env: hermes_exec.TerminalEnv,
    api_key: String,
    base_url: String,
    budget: iteration_budget.IterationBudget,
    system_prompt: String,
    on_event: Option(fn(AgentEvent) -> Nil),
    mcp_client: Option(mcp_client.McpClient),
    /// Model router: primary + fallback chain, inspired by lm-eval-harness TemplateAPI
    router: Option(ModelRouter),
  )
}

pub fn with_event_handler(state: AgentState, handler: fn(AgentEvent) -> Nil) -> AgentState {
  AgentState(..state, on_event: Some(handler))
}

/// Tool call parsed from LLM response JSON
pub type ToolCall {
  ToolCall(id: String, name: String, arguments: String)
}

/// A complete parsed LLM API response turn
pub type AgentResponse {
  FinalText(content: String)
  ToolCalls(calls: List(ToolCall))
  EmptyResponse
  ErrorResponse(reason: String)
}

// ─── Tool Dispatcher ───────────────────────────────────────────────────────────

/// Execute a single tool call and return its result as a JSON string.
pub fn dispatch_tool(
  state: AgentState,
  call: ToolCall,
  quiet: Bool,
) -> #(hermes_exec.TerminalEnv, String) {
  let exec_env = state.exec_env
  case call.name {
    "run_command" -> {
      let command = case json.parse(from: call.arguments, using: {
        use cmd <- decode.field("command", decode.string)
        decode.success(cmd)
      }) {
        Ok(cmd) -> cmd
        Error(_) -> "echo 'Error: could not parse command argument'"
      }
      case quiet {
        False -> io.println("  [tool: run_command] $ " <> command)
        True -> Nil
      }
      let #(new_env, result) = hermes_exec.execute(exec_env, command, "", None)
      case result {
        Ok(#(output, exit_code)) -> {
          let result_json =
            json.object([
              #("output", json.string(output)),
              #("exit_code", json.int(exit_code)),
            ])
            |> json.to_string
          #(new_env, result_json)
        }
        Error(err) -> {
          let result_json =
            json.object([#("error", json.string(err))])
            |> json.to_string
          #(new_env, result_json)
        }
      }
    }

    "write_file" -> {
      let parsed = json.parse(from: call.arguments, using: {
        use path <- decode.field("path", decode.string)
        use content <- decode.field("content", decode.string)
        decode.success(#(path, content))
      })
      case parsed {
        Ok(#(path, content)) -> {
          case quiet {
            False -> io.println("  [tool: write_file] -> " <> path)
            True -> Nil
          }
          let full_path = case string.starts_with(path, "/") {
            True -> path
            False -> exec_env.cwd <> "/" <> path
          }
          let write_result =
            do_write_file(full_path, content)
          let result_json = case write_result {
            Ok(_) ->
              json.object([#("status", json.string("ok")), #("path", json.string(full_path))])
              |> json.to_string
            Error(err) ->
              json.object([#("error", json.string(err))])
              |> json.to_string
          }
          #(exec_env, result_json)
        }
        Error(_) ->
          #(exec_env, json.object([#("error", json.string("Invalid write_file arguments"))]) |> json.to_string)
      }
    }

    "read_file" -> {
      let parsed = json.parse(from: call.arguments, using: {
        use path <- decode.field("path", decode.string)
        decode.success(path)
      })
      case parsed {
        Ok(path) -> {
          case quiet {
            False -> io.println("  [tool: read_file] <- " <> path)
            True -> Nil
          }
          let full_path = case string.starts_with(path, "/") {
            True -> path
            False -> exec_env.cwd <> "/" <> path
          }
          let read_result = do_read_file(full_path)
          let result_json = case read_result {
            Ok(contents) ->
              json.object([#("contents", json.string(contents))])
              |> json.to_string
            Error(err) ->
              json.object([#("error", json.string(err))])
              |> json.to_string
          }
          #(exec_env, result_json)
        }
        Error(_) ->
          #(exec_env, json.object([#("error", json.string("Invalid read_file arguments"))]) |> json.to_string)
      }
    }

    unknown -> {
      case quiet {
        False -> io.println("  [tool: mcp call] " <> unknown)
        True -> Nil
      }
      let result_json = case state.mcp_client {
        Some(client) -> {
          case mcp_client.call_tool(client, unknown, call.arguments) {
            Ok(res) -> res
            Error(err) -> json.object([#("error", json.string(err))]) |> json.to_string
          }
        }
        None -> {
          json.object([
            #(
              "error",
              json.string(
                "Unknown tool: " <> unknown <> ". Available statically: run_command, write_file, read_file",
              ),
            ),
          ])
          |> json.to_string
        }
      }
      #(exec_env, result_json)
    }
  }
}

// ─── FFI Bindings for file I/O ─────────────────────────────────────────────────

@external(erlang, "hermes_agent_ffi", "write_file")
fn do_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "hermes_agent_ffi", "read_file")
fn do_read_file(path: String) -> Result(String, String)

@external(erlang, "erlang", "system_time")
fn system_time_ms() -> Int

// ─── Tool Schema Builder ───────────────────────────────────────────────────────

/// Returns the JSON string for all registered tool schemas to include in API requests.
pub fn all_tool_schemas(mcp_client: Option(mcp_client.McpClient)) -> String {
  let base_schemas = run_command_schema <> "," <> write_file_schema <> "," <> read_file_schema
  case mcp_client {
    Some(client) -> {
      case mcp_client.list_tools(client) {
        Ok(tools) -> {
          let mcp_schemas = list.map(tools, fn(t) {
            "{\"type\":\"function\",\"function\":{\"name\":\"" <> t.name <> "\",\"description\":\"" <> t.description <> "\",\"parameters\":" <> t.input_schema <> "}}"
          }) |> string.join(",")
          case mcp_schemas == "" {
            True -> "[" <> base_schemas <> "]"
            False -> "[" <> base_schemas <> "," <> mcp_schemas <> "]"
          }
        }
        Error(_) -> "[" <> base_schemas <> "]"
      }
    }
    None -> "[" <> base_schemas <> "]"
  }
}

// ─── Response Parsing ──────────────────────────────────────────────────────────

/// Decode a tool_call JSON fragment into a ToolCall record.
pub fn decode_tool_call(data: json.Json) -> Option(ToolCall) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use function <- decode.field("function", {
      use name <- decode.field("name", decode.string)
      use arguments <- decode.field("arguments", decode.string)
      decode.success(#(name, arguments))
    })
    decode.success(ToolCall(id: id, name: function.0, arguments: function.1))
  }
  let json_str = json.to_string(data)
  case json.parse(from: json_str, using: decoder) {
    Ok(tc) -> Some(tc)
    Error(_) -> None
  }
}

/// Parse a complete (non-streaming) OpenAI chat completion JSON response.
pub fn parse_completion_response(json_str: String) -> AgentResponse {
  let text_decoder = {
    use choices <- decode.field("choices", decode.list({
      use message <- decode.field("message", {
        use content <- decode.field("content", decode.string)
        decode.success(content)
      })
      decode.success(message)
    }))
    decode.success(choices)
  }

  let tool_decoder = {
    use choices <- decode.field("choices", decode.list({
      use message <- decode.field("message", {
        use tool_calls <- decode.field("tool_calls", decode.list(decode.dynamic))
        decode.success(tool_calls)
      })
      decode.success(message)
    }))
    decode.success(choices)
  }

  // Try to parse as tool calls first
  case json.parse(from: json_str, using: tool_decoder) {
    Ok([[first_dyn_call, ..] as dyn_calls, ..]) -> {
      let _ = first_dyn_call
      // Encode each dynamic value back to json for decode_tool_call
      let raw_json_values = list.map(dyn_calls, fn(dyn) {
        let _ = dyn
        // Use dynamic decoder to extract tool call fields
        json.null()
      })
      let _ = raw_json_values
      // Parse tool calls from raw JSON strings
      let tool_calls = parse_tool_calls_from_json(json_str)
      case tool_calls {
        [] -> EmptyResponse
        calls -> ToolCalls(calls)
      }
    }
    _ -> {
      // Try text content
      case json.parse(from: json_str, using: text_decoder) {
        Ok([content, ..]) -> FinalText(content)
        Ok([]) -> EmptyResponse
        Error(_) -> EmptyResponse
      }
    }
  }
}

/// Parse tool calls directly from a raw JSON string.
/// Handles the OpenAI format: choices[0].message.tool_calls[].
pub fn parse_tool_calls_from_json(json_str: String) -> List(ToolCall) {
  let decoder = {
    use choices <- decode.field("choices", decode.list({
      use message <- decode.field("message", {
        use tool_calls <- decode.field("tool_calls", decode.list({
          use id <- decode.field("id", decode.string)
          use function <- decode.field("function", {
            use name <- decode.field("name", decode.string)
            use arguments <- decode.field("arguments", decode.string)
            decode.success(#(name, arguments))
          })
          decode.success(ToolCall(id: id, name: function.0, arguments: function.1))
        }))
        decode.success(tool_calls)
      })
      decode.success(message)
    }))
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([first_choice_calls, ..]) -> first_choice_calls
    _ -> []
  }
}

/// Parse finish_reason from a completion response JSON.
pub fn parse_finish_reason(json_str: String) -> String {
  let decoder = {
    use choices <- decode.field("choices", decode.list({
      use finish_reason <- decode.field("finish_reason", decode.string)
      decode.success(finish_reason)
    }))
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([reason, ..]) -> reason
    _ -> "stop"
  }
}

// ─── SSE delta content extractor (reused from hermes_beam) ────────────────────

fn decode_openai_delta(json_str: String) -> Result(String, Nil) {
  let decoder = {
    use choices <- decode.field("choices", decode.list({
      use delta <- decode.field("delta", {
        use content <- decode.field("content", decode.string)
        decode.success(content)
      })
      decode.success(delta)
    }))
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([content, ..]) -> Ok(content)
    _ -> Error(Nil)
  }
}

fn decode_openai_delta_tool_calls(json_str: String) -> Bool {
  // If choices[0].delta has tool_calls, we're in a tool call stream
  let decoder = {
    use choices <- decode.field("choices", decode.list({
      use delta <- decode.field("delta", {
        use tool_calls <- decode.field("tool_calls", decode.list(decode.dynamic))
        decode.success(tool_calls)
      })
      decode.success(delta)
    }))
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([[_first_tc, ..], ..]) -> True
    _ -> False
  }
}

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
    tool_calls: Dict(Int, PartialToolCall),
  )
}

fn decode_delta_tool_calls(json_str: String) -> List(#(Int, PartialToolCall)) {
  let tc_decoder = {
    use index <- decode.field("index", decode.int)
    use id <- decode.optional_field("id", "", decode.string)
    use function <- decode.optional_field("function", None, {
      use name <- decode.optional_field("name", "", decode.string)
      use arguments <- decode.optional_field("arguments", "", decode.string)
      decode.success(Some(#(name, arguments)))
    })
    let #(name, arguments) = case function {
      Some(#(n, a)) -> #(n, a)
      None -> #("", "")
    }
    decode.success(#(index, PartialToolCall(id: id, name: name, arguments_acc: arguments)))
  }
  let decoder = {
    use choices <- decode.field("choices", decode.list({
      use delta <- decode.field("delta", {
        use tool_calls <- decode.field("tool_calls", decode.list(tc_decoder))
        decode.success(tool_calls)
      })
      decode.success(delta)
    }))
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([tcs, ..]) -> tcs
    _ -> []
  }
}

/// Decode streaming delta text from an SSE JSON line.
/// Tries OpenAI delta format first, then Anthropic text format.
pub fn extract_delta_content(json_str: String) -> String {
  case decode_openai_delta(json_str) {
    Ok(text) -> text
    Error(_) -> {
      let anthropic_decoder = {
        use delta <- decode.field("delta", {
          use text <- decode.field("text", decode.string)
          decode.success(text)
        })
        decode.success(delta)
      }
      case json.parse(from: json_str, using: anthropic_decoder) {
        Ok(text) -> text
        Error(_) -> ""
      }
    }
  }
}

// ─── Streaming Response Collector ─────────────────────────────────────────────

/// Streams an SSE response from the LLM, printing delta text to stdout
/// and accumulating the full content. Returns the full accumulated response.
pub fn stream_and_collect(
  req_id: hermes_client.ReqId,
  parser: LineParserState,
  accumulated: StreamAccumulator,
  on_delta: Option(fn(String) -> Nil),
) -> #(StreamAccumulator, Bool) {
  // Allow configuring timeout via env var for slow free-tier models (default: 300s)
  let timeout_ms = case constants.get_env("HERMES_STREAM_TIMEOUT_MS") {
    Some(val) -> case int.parse(val) { Ok(n) -> n  Error(_) -> 300_000 }
    None -> 300_000
  }
  case hermes_client.receive_stream_chunk(req_id, timeout_ms) {
    StreamStart(_) ->
      stream_and_collect(req_id, parser, accumulated, on_delta)

    StreamChunk(chunk) -> {
      let #(lines, next_parser) = hermes_client.feed_chunk(parser, chunk)
      let #(new_acc, saw_tool_call) =
        list.fold(lines, #(accumulated, False), fn(state, line) {
          let #(acc, tc_seen) = state
          case hermes_client.parse_sse_line(line) {
            Some(json_str) -> {
              let text_delta = case decode_openai_delta(json_str) {
                Ok(text) -> {
                  case on_delta {
                    Some(handler) -> handler(text)
                    None -> io.print(text)
                  }
                  text
                }
                Error(_) -> ""
              }
              
              let tcs = decode_delta_tool_calls(json_str)
              let new_tcs = list.fold(tcs, acc.tool_calls, fn(tc_dict, tc_tuple) {
                let #(index, ptc) = tc_tuple
                case dict.get(tc_dict, index) {
                  Ok(existing) -> {
                    let new_id = case ptc.id {
                      "" -> existing.id
                      id -> id
                    }
                    let new_name = case ptc.name {
                      "" -> existing.name
                      name -> name
                    }
                    let new_args = existing.arguments_acc <> ptc.arguments_acc
                    dict.insert(tc_dict, index, PartialToolCall(new_id, new_name, new_args))
                  }
                  Error(_) -> {
                    dict.insert(tc_dict, index, ptc)
                  }
                }
              })
              let tc_seen_now = tcs != []
              let is_tool_call = decode_openai_delta_tool_calls(json_str)
              
              let updated_acc = StreamAccumulator(
                text: acc.text <> text_delta,
                tool_calls: new_tcs,
              )
              #(updated_acc, tc_seen || is_tool_call || tc_seen_now)
            }
            None -> #(acc, tc_seen)
          }
        })
      stream_and_collect(req_id, next_parser, new_acc, on_delta)
      |> fn(result) {
        let #(final_acc, final_tc) = result
        #(final_acc, final_tc || saw_tool_call)
      }
    }

    StreamEnd -> {
      case on_delta {
        None -> io.println("")
        Some(_) -> Nil
      }
      #(accumulated, False)
    }

    StreamError(reason) -> {
      let msg = "\n[Stream Error: " <> reason <> "]"
      case on_delta {
        None -> io.println(msg)
        Some(_) -> Nil
      }
      // Return error marker so agent_turn_loop knows it's an API failure
      #(StreamAccumulator(text: "__STREAM_ERROR__:" <> reason, tool_calls: dict.new()), False)
    }

    StreamTimeout -> {
      let msg = "\n[Stream Timeout — model may be down or key exhausted]"
      case on_delta {
        None -> io.println(msg)
        Some(_) -> Nil
      }
      #(StreamAccumulator(text: "__STREAM_ERROR__:timeout", tool_calls: dict.new()), False)
    }
  }
}

// ─── Build OpenAI Request Body ─────────────────────────────────────────────────

/// Build an OpenAI-compatible chat completion request body JSON string.
/// Applies a sliding window: keeps newest 60 messages when history > 80
/// to prevent context window overflow on long /goal runs.
pub fn build_request_body(
  model: String,
  system_prompt: String,
  history: List(String),
  tools: String,
  stream: Bool,
) -> String {
  let system_msg =
    json.object([
      #("role", json.string("system")),
      #("content", json.string(system_prompt)),
    ]) |> json.to_string

  // Sliding window: trim to newest 60 messages when history exceeds 80
  let window_size = 60
  let max_history = 80
  let trimmed_history = case list.length(history) > max_history {
    True -> list.take(history, window_size)
    False -> history
  }

  let all_messages = [system_msg, ..trimmed_history]

  // Parse tools JSON string into a json.Json value for embedding
  let tools_json = case json.parse(from: tools, using: decode.dynamic) {
    Ok(_) -> tools
    Error(_) -> "[]"
  }

  "{\"model\":\""
  <> model
  <> "\",\"messages\":["
  <> string.join(list.reverse(all_messages), ",")
  <> "],\"tools\":"
  <> tools_json
  <> ",\"stream\":"
  <> case stream {
    True -> "true"
    False -> "false"
  }
  <> "}"
}

// ─── Message History Builders ──────────────────────────────────────────────────

pub fn user_message(content: String) -> String {
  json.object([
    #("role", json.string("user")),
    #("content", json.string(content)),
  ]) |> json.to_string
}

pub fn assistant_message(content: String) -> String {
  json.object([
    #("role", json.string("assistant")),
    #("content", json.string(content)),
  ]) |> json.to_string
}

pub fn assistant_tool_calls_message(calls: List(ToolCall)) -> String {
  let tool_calls_json =
    list.map(calls, fn(tc) {
      json.object([
        #("id", json.string(tc.id)),
        #("type", json.string("function")),
        #(
          "function",
          json.object([
            #("name", json.string(tc.name)),
            #("arguments", json.string(tc.arguments)),
          ]),
        ),
      ])
    })
  json.object([
    #("role", json.string("assistant")),
    #("content", json.null()),
    #("tool_calls", json.array(tool_calls_json, of: fn(x) { x })),
  ]) |> json.to_string
}

pub fn tool_result_message(tool_call_id: String, result: String) -> String {
  json.object([
    #("role", json.string("tool")),
    #("tool_call_id", json.string(tool_call_id)),
    #("content", json.string(result)),
  ]) |> json.to_string
}

// ─── Core Agent Loop ───────────────────────────────────────────────────────────

/// Execute one agent turn:
/// 1. Build request with current history + tools
/// 2. Send to LLM via streaming POST
/// 3. Accumulate response or collect tool calls
/// 4. If tool calls: execute each, append results, recurse
/// 5. If final text: persist and return
pub fn agent_turn_loop(
  state: AgentState,
  api_call_count: Int,
) -> Result(AgentState, String) {
  let quiet = option.is_some(state.on_event)
  // Budget check
  case iteration_budget.consume(state.budget) {
    False -> {
      let budget_used = iteration_budget.used(state.budget)
      case quiet {
        False -> {
          io.println(
            "\n⚠️  Iteration budget exhausted ("
            <> int.to_string(budget_used)
            <> " iterations used)",
          )
        }
        True -> Nil
      }
      Error("Budget exhausted after " <> int.to_string(api_call_count) <> " iterations")
    }

    True -> {
      // Resolve active model from router (if present) or fall back to state.model
      let active_model = case state.router {
        Some(router) -> model_router.current_model(router)
        None -> state.model
      }
      case quiet {
        False -> {
          io.println(
            "\n🔄 API call #"
            <> int.to_string(api_call_count + 1)
            <> " (model: "
            <> active_model
            <> ")",
          )
        }
        True -> Nil
      }

      let active_model2 = case state.router {
        Some(router) -> model_router.current_model(router)
        None -> state.model
      }
      let body = build_request_body(
        active_model2,
        state.system_prompt,
        list.reverse(state.history),
        all_tool_schemas(state.mcp_client),
        True,
      )

      let headers = [
        #("Authorization", "Bearer " <> state.api_key),
        #("Content-Type", "application/json"),
        #("Accept", "text/event-stream"),
      ]

      case hermes_client.stream_post_request(
        state.base_url <> "/chat/completions",
        headers,
        "application/json",
        body,
      ) {
        Error(err) -> {
          case quiet {
            False -> io.println("\n[API Error: " <> err <> "]")
            True -> Nil
          }
          Error("API request failed: " <> err)
        }

        Ok(req_id) -> {
          // Collect streaming response
          let on_delta = case state.on_event {
            Some(handler) -> Some(fn(delta) { handler(MessageDelta(delta)) })
            None -> None
          }
          let initial_acc = StreamAccumulator("", dict.new())
          let #(final_acc, _saw_tool_calls_in_stream) =
            stream_and_collect(req_id, hermes_client.new_line_parser(), initial_acc, on_delta)

          let response_trimmed = string.trim(final_acc.text)
          let agent_resp = case dict.size(final_acc.tool_calls) > 0 {
            True -> {
              let calls = dict.values(final_acc.tool_calls)
                |> list.map(fn(ptc) {
                  ToolCall(id: ptc.id, name: ptc.name, arguments: ptc.arguments_acc)
                })
              ToolCalls(calls)
            }
            False -> {
              case response_trimmed {
                "" -> fetch_fallback_non_streaming(state, body)
                text -> {
                  case string.starts_with(text, "__STREAM_ERROR__:") {
                    True -> {
                      let reason = string.drop_start(text, 17)
                      ErrorResponse("Stream failed: " <> reason)
                    }
                    False -> FinalText(text)
                  }
                }
              }
            }
          }

          case agent_resp {
            // ── Tool call path ──────────────────────────────────────────────
            ToolCalls(calls) -> {
              case state.on_event {
                Some(handler) -> {
                  list.each(calls, fn(tc) {
                    handler(ToolStart(tc.name, tc.arguments))
                  })
                }
                None -> {
                  io.println("\n🔧 Executing " <> int.to_string(list.length(calls)) <> " tool call(s)...")
                }
              }

              let calls_msg = assistant_tool_calls_message(calls)
              let _ = state_actor.insert_message(
                state.db_conn,
                state.session_id,
                "assistant",
                "",
                calls_msg,
                int.to_float(system_time_ms()) /. 1000.0,
              )
              // Append the assistant's tool_calls message to history
              let history_with_assistant =
                [calls_msg, ..state.history]

              // Execute each tool and collect results
              let #(new_exec_env, new_history) =
                list.fold(calls, #(state.exec_env, history_with_assistant), fn(acc, tc) {
                  let #(current_env, current_history) = acc
                  let #(next_env, result) = dispatch_tool(AgentState(..state, exec_env: current_env), tc, quiet)
                  case state.on_event {
                    Some(handler) -> handler(ToolComplete(tc.name, result))
                    None -> Nil
                  }
                  let tool_msg = tool_result_message(tc.id, result)
                let _ = state_actor.insert_message(
                  state.db_conn,
                  state.session_id,
                  "tool",
                  result,
                  tool_msg,
                  int.to_float(system_time_ms()) /. 1000.0,
                )
                #(next_env, [tool_msg, ..current_history])
                })

              // Recurse with updated state
              agent_turn_loop(
                AgentState(
                  ..state,
                  exec_env: new_exec_env,
                  history: new_history,
                  cwd: new_exec_env.cwd,
                ),
                api_call_count + 1,
              )
            }

            // ── Final text response path ─────────────────────────────────────
            FinalText(final_text) -> {
              // Record assistant response in DB
              let timestamp =
                int.to_float(system_time_ms()) /. 1000.0
              let asst_msg = assistant_message(final_text)
              let _ =
                state_actor.insert_message(
                  state.db_conn,
                  state.session_id,
                  "assistant",
                  final_text,
                  asst_msg,
                  timestamp,
                )

              case state.on_event {
                Some(handler) -> handler(MessageComplete(final_text))
                None -> Nil
              }

              let new_history =
                [assistant_message(final_text), ..state.history]

              Ok(AgentState(..state, history: new_history))
            }

            // ── Error response path — classify and attempt model fallback ────
            // Inspired by lm-eval-harness per-error-type retry config:
            // auth errors advance immediately, timeouts retry then advance.
            ErrorResponse(reason) -> {
              let classified = error_classifier.classify(reason)
              case quiet {
                False ->
                  io.println(
                    "\n"
                    <> classified.emoji
                    <> " "
                    <> error_classifier.label(classified)
                    <> " Error: "
                    <> reason,
                  )
                True -> Nil
              }
              case state.router {
                Some(router) -> {
                  case model_router.mark_failure(router, classified.kind) {
                    Ok(next_router) -> {
                      let next_model = model_router.current_model(next_router)
                      case quiet {
                        False ->
                          io.println(
                            "⚡ Switching model: "
                            <> model_router.current_model(router)
                            <> " → "
                            <> next_model,
                          )
                        True -> Nil
                      }
                      // Retry the turn with the next model in the chain
                      agent_turn_loop(
                        AgentState(..state, router: Some(next_router)),
                        api_call_count + 1,
                      )
                    }
                    Error(exhausted_msg) -> {
                      case quiet {
                        False -> io.println("❌ " <> exhausted_msg)
                        True -> Nil
                      }
                      Error("API error: " <> reason)
                    }
                  }
                }
                None -> Error("API error: " <> reason)
              }
            }

            _ -> {
              let final_text = "[No response from model]"
              let timestamp =
                int.to_float(system_time_ms()) /. 1000.0
              let asst_msg = assistant_message(final_text)
              let _ =
                state_actor.insert_message(
                  state.db_conn,
                  state.session_id,
                  "assistant",
                  final_text,
                  asst_msg,
                  timestamp,
                )

              case state.on_event {
                Some(handler) -> handler(MessageComplete(final_text))
                None -> Nil
              }

              let new_history =
                [assistant_message(final_text), ..state.history]

              Ok(AgentState(..state, history: new_history))
            }
          }
        }
      }
    }
  }
}

/// Fallback: send a non-streaming request to get the response (text or tool calls)
/// when streaming response was empty or timed out.
pub fn fetch_fallback_non_streaming(
  state: AgentState,
  _streaming_body: String,
) -> AgentResponse {
  // Build non-streaming body
  let body = build_request_body(
    state.model,
    state.system_prompt,
    list.reverse(state.history),
    all_tool_schemas(state.mcp_client),
    False,
  )

  let headers = [
    #("Authorization", "Bearer " <> state.api_key),
    #("Content-Type", "application/json"),
  ]

  case hermes_client.post_request_with_retry(
    state.base_url <> "/chat/completions",
    headers,
    "application/json",
    body,
  ) {
    Ok(response_json) -> parse_completion_response(response_json)
    Error(err) -> ErrorResponse(err)
  }
}

// ─── Public Entry Point ────────────────────────────────────────────────────────

/// Run a multi-turn conversation with the LLM, handling tool calls recursively.
pub fn run_conversation(
  state: AgentState,
  user_prompt: String,
) -> Result(AgentState, String) {
  let timestamp = int.to_float(system_time_ms()) /. 1000.0

  // Persist user message
  let user_msg = user_message(user_prompt)
  let _ =
    state_actor.insert_message(
      state.db_conn,
      state.session_id,
      "user",
      user_prompt,
      user_msg,
      timestamp,
    )

  // Append user message to history
  let new_history = [user_message(user_prompt), ..state.history]
  let new_state = AgentState(..state, history: new_history)

  agent_turn_loop(new_state, 0)
}

/// Create a new AgentState with a fresh iteration budget.
pub fn new_agent_state(
  session_id: String,
  model: String,
  cwd: String,
  db_conn: StateActor,
  exec_env: hermes_exec.TerminalEnv,
  api_key: String,
  base_url: String,
  system_prompt: String,
  max_iterations: Int,
  mcp_client: Option(mcp_client.McpClient),
) -> Result(AgentState, String) {
  case iteration_budget.start(max_iterations) {
    Ok(budget) ->
      Ok(AgentState(
        session_id: session_id,
        model: model,
        cwd: cwd,
        history: [],
        db_conn: db_conn,
        exec_env: exec_env,
        api_key: api_key,
        base_url: base_url,
        budget: budget,
        system_prompt: system_prompt,
        on_event: None,
        mcp_client: mcp_client,
        router: None,
      ))
    Error(_) ->
      Error("Failed to start iteration budget actor")
  }
}
