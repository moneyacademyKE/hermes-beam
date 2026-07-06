import constants
import context_engine
import error_classifier
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import hermes_client.{
  type LineParserState, StreamChunk, StreamEnd, StreamError, StreamStart,
  StreamTimeout,
}
import hermes_exec
import hermes_logger
import iteration_budget
import kawaii_spinner
import mcp_client
import memory_plugin
import model_router.{type ModelRouter}
import prompt_cache
import compaction
import git_worktree
import browser_cdp
import vector_memory
import state_actor.{type StateActor}
import token_budget
import tools_registry
import circuit_breaker_actor
import glotel/span

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
    circuit_breaker: Option(circuit_breaker_actor.CircuitBreaker),
    token_budget: Option(token_budget.TokenBudget),
    tool_policy: ToolPolicy,
  )
}

pub type ToolCapability {
  RunCommand
  ReadFile
  WriteFile
  UseMcp
  UseWorkers
}

pub type ToolPolicy {
  ToolPolicy(capabilities: List(ToolCapability))
}

pub fn default_tool_policy() -> ToolPolicy {
  ToolPolicy(capabilities: [RunCommand, ReadFile, WriteFile, UseMcp, UseWorkers])
}

pub fn restricted_tool_policy() -> ToolPolicy {
  ToolPolicy(capabilities: [ReadFile])
}

pub fn tool_policy_allows(policy: ToolPolicy, capability: ToolCapability) -> Bool {
  list.any(policy.capabilities, fn(allowed) { allowed == capability })
}

pub fn tool_policy_allows_tool(policy: ToolPolicy, name: String) -> Bool {
  case name {
    "run_command" -> tool_policy_allows(policy, RunCommand)
    "read_file" -> tool_policy_allows(policy, ReadFile)
    "write_file" -> tool_policy_allows(policy, WriteFile)
    "handoff_session" -> tool_policy_allows(policy, UseWorkers)
    _ -> True
  }
}

fn env_flag_enabled(name: String) -> Bool {
  case constants.get_env(name) {
    Some(value) -> case string.lowercase(string.trim(value)) {
      "1" | "true" | "yes" | "on" -> True
      _ -> False
    }
    None -> False
  }
}

pub fn with_tool_policy(state: AgentState, tool_policy: ToolPolicy) -> AgentState {
  AgentState(..state, tool_policy: tool_policy)
}

pub fn with_event_handler(
  state: AgentState,
  handler: fn(AgentEvent) -> Nil,
) -> AgentState {
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
  hermes_logger.info(state.session_id, "Dispatching tool call: " <> call.name)
  hermes_logger.event("INFO", state.session_id, "tool_call_started", [
    #("tool", call.name),
  ])
  case call.name {
    "run_command" -> {
      case tool_policy_allows(state.tool_policy, RunCommand) {
        False -> #(
          exec_env,
          json.object([#("error", json.string("run_command is disabled for this session"))])
            |> json.to_string,
        )
        True -> {
          let command = case
            json.parse(from: call.arguments, using: {
              use cmd <- decode.field("command", decode.string)
              decode.success(cmd)
            })
          {
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
              hermes_logger.failure(state.session_id, "tool_call_failed", err, [
                #("tool", call.name),
              ])
              let result_json =
                json.object([#("error", json.string(err))])
                |> json.to_string
              #(new_env, result_json)
            }
          }
        }
      }
    }

    "write_file" -> {
      case tool_policy_allows(state.tool_policy, WriteFile) {
        False -> #(
          exec_env,
          json.object([#("error", json.string("write_file is disabled for this session"))])
            |> json.to_string,
        )
        True -> {
          let parsed =
            json.parse(from: call.arguments, using: {
              use path <- decode_file_path_argument()
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
              let write_result = do_write_file(full_path, content)
              let result_json = case write_result {
                Ok(_) ->
                  json.object([
                    #("status", json.string("ok")),
                    #("path", json.string(full_path)),
                  ])
                  |> json.to_string
                Error(err) -> {
                  hermes_logger.failure(state.session_id, "tool_call_failed", err, [
                    #("tool", call.name),
                  ])
                  json.object([#("error", json.string(err))])
                  |> json.to_string
                }
              }
              #(exec_env, result_json)
            }
            Error(_) -> {
              let err = "Invalid write_file arguments"
              hermes_logger.failure(state.session_id, "tool_call_failed", err, [
                #("tool", call.name),
              ])
              #(
                exec_env,
                json.object([#("error", json.string(err))])
                  |> json.to_string,
              )
            }
          }
        }
      }
    }

    "read_file" -> {
      case tool_policy_allows(state.tool_policy, ReadFile) {
        False -> #(
          exec_env,
          json.object([#("error", json.string("read_file is disabled for this session"))])
            |> json.to_string,
        )
        True -> {
          let parsed =
            json.parse(from: call.arguments, using: decode_file_path())
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
                Error(err) -> {
                  hermes_logger.failure(state.session_id, "tool_call_failed", err, [
                    #("tool", call.name),
                  ])
                  json.object([#("error", json.string(err))])
                  |> json.to_string
                }
              }
              #(exec_env, result_json)
            }
            Error(_) -> {
              let err = "Invalid read_file arguments"
              hermes_logger.failure(state.session_id, "tool_call_failed", err, [
                #("tool", call.name),
              ])
              #(
                exec_env,
                json.object([#("error", json.string(err))])
                  |> json.to_string,
              )
            }
          }
        }
      }
    }

    "semantic_search_history" -> {
      case env_flag_enabled("HERMES_ENABLE_SEMANTIC_SEARCH") {
        False -> #(
          exec_env,
          json.object([#("error", json.string("semantic_search_history is disabled; set HERMES_ENABLE_SEMANTIC_SEARCH=true to expose it"))])
            |> json.to_string,
        )
        True -> {
          let parsed =
            json.parse(from: call.arguments, using: {
              use query <- decode.field("query", decode.string)
              decode.success(query)
            })
          case parsed {
            Ok(query) -> {
              case quiet {
                False -> io.println("  [tool: semantic_search_history] ? " <> query)
                True -> Nil
              }
              let store = vector_memory.new()
              let results =
                vector_memory.search(store, query, state.api_key, limit: 5)
              let result_json =
                json.object([
                  #("status", json.string("ok")),
                  #("query", json.string(query)),
                  #("results", json.array(
                    list.map(results, fn(r) {
                      json.object([
                        #("content", json.string(r.content)),
                        #("session_id", json.string(r.session_id)),
                        #("score", json.float(r.score)),
                        #("source", json.string(r.source)),
                      ])
                    }),
                    of: fn(x) { x },
                  )),
                  #("count", json.int(list.length(results))),
                ])
                |> json.to_string
              #(exec_env, result_json)
            }
            Error(_) -> #(
              exec_env,
              json.object([#("error", json.string("Invalid search arguments"))])
                |> json.to_string,
            )
          }
        }
      }
    }

    "handoff_session" -> {
      case tool_policy_allows(state.tool_policy, UseWorkers) {
        False -> #(
          exec_env,
          json.object([#("error", json.string("handoff_session is disabled for this session"))])
            |> json.to_string,
        )
        True -> {
          let parsed =
            json.parse(from: call.arguments, using: {
              use target <- decode.field("target_session_id", decode.string)
              use context <- decode.field("handoff_context", decode.string)
              decode.success(#(target, context))
            })
          case parsed {
            Ok(#(target, context)) -> {
              case quiet {
                False -> io.println("  [tool: handoff_session] -> " <> target)
                True -> Nil
              }
              let timestamp = int.to_float(system_time_ms()) /. 1000.0
              let handoff_msg =
                "<handoff_context>\n" <> context <> "\n</handoff_context>"
              let _ =
                state_actor.insert_message(
                  state.db_conn,
                  target,
                  "system",
                  handoff_msg,
                  handoff_msg,
                  timestamp,
                )
              let result_json =
                json.object([
                  #(
                    "status",
                    json.string("handoff payload injected to target session"),
                  ),
                ])
                |> json.to_string
              #(exec_env, result_json)
            }
            Error(_) -> #(
              exec_env,
              json.object([#("error", json.string("Invalid handoff arguments"))])
                |> json.to_string,
            )
          }
        }
      }
    }

    "create_worktree" -> {
      let agent_id = case json.parse(from: call.arguments, using: {
        use aid <- decode.field("agent_id", decode.string)
        decode.success(aid)
      }) {
        Ok(aid) -> aid
        Error(_) -> "default"
      }
      case quiet {
        False -> io.println("  [tool: create_worktree] agent_id=" <> agent_id)
        True -> Nil
      }
      let result = git_worktree.tool_create_worktree(exec_env.cwd, agent_id)
      #(exec_env, result)
    }

    "diff_worktree" -> {
      let agent_id = case json.parse(from: call.arguments, using: {
        use aid <- decode.field("agent_id", decode.string)
        decode.success(aid)
      }) {
        Ok(aid) -> aid
        Error(_) -> "default"
      }
      case quiet {
        False -> io.println("  [tool: diff_worktree] agent_id=" <> agent_id)
        True -> Nil
      }
      let result = git_worktree.tool_diff_worktree(exec_env.cwd, agent_id)
      #(exec_env, result)
    }

    "browser_navigate" -> {
      let url = case json.parse(from: call.arguments, using: {
        use u <- decode.field("url", decode.string)
        decode.success(u)
      }) {
        Ok(u) -> u
        Error(_) -> ""
      }
      case quiet {
        False -> io.println("  [tool: browser_navigate] " <> url)
        True -> Nil
      }
      let bstate = browser_cdp.new(True)
      let #(new_state, result) = browser_cdp.tool_navigate(bstate, url)
      let _ = browser_cdp.cleanup(new_state)
      #(exec_env, result)
    }

    "browser_screenshot" -> {
      let path = case json.parse(from: call.arguments, using: {
        use p <- decode.field("path", decode.string)
        decode.success(p)
      }) {
        Ok(p) -> p
        Error(_) -> "screenshot.png"
      }
      case quiet {
        False -> io.println("  [tool: browser_screenshot] -> " <> path)
        True -> Nil
      }
      let bstate = browser_cdp.new(True)
      let #(new_state, result) = browser_cdp.tool_screenshot(bstate, path)
      let _ = browser_cdp.cleanup(new_state)
      #(exec_env, result)
    }

    unknown -> {
      case quiet {
        False -> io.println("  [tool: mcp call] " <> unknown)
        True -> Nil
      }
      let result_json = case state.mcp_client {
        Some(client) -> {
          case tool_policy_allows(state.tool_policy, UseMcp) {
            False ->
              json.object([#("error", json.string("MCP tools are disabled for this session"))])
              |> json.to_string
            True -> {
              case mcp_client.call_tool(client, unknown, call.arguments) {
                Ok(res) -> res
                Error(err) -> {
                  hermes_logger.failure(state.session_id, "mcp_tool_call_failed", err, [
                    #("tool", unknown),
                  ])
                  json.object([#("error", json.string(err))]) |> json.to_string
                }
              }
            }
          }
        }
        None -> {
          hermes_logger.failure(state.session_id, "tool_call_failed", "Unknown tool", [
            #("tool", unknown),
          ])
          json.object([
            #(
              "error",
              json.string(
                "Unknown tool: "
                <> unknown
                <> ". Available statically: run_command, write_file, read_file",
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

/// Decode the canonical `path` tool argument, while accepting the older
/// `file_path` spelling from stale clients or model context.
pub fn decode_file_path() -> decode.Decoder(String) {
  decode.one_of(
    {
      use path <- decode.field("path", decode.string)
      decode.success(path)
    },
    or: [
      {
        use file_path <- decode.field("file_path", decode.string)
        decode.success(file_path)
      },
    ],
  )
}

pub fn decode_file_path_argument(
  next: fn(String) -> decode.Decoder(t),
) -> decode.Decoder(t) {
  decode.then(decode_file_path(), next)
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
  all_tool_schemas_with_policy(mcp_client, default_tool_policy())
}

pub fn all_tool_schemas_with_policy(
  mcp_client: Option(mcp_client.McpClient),
  tool_policy: ToolPolicy,
) -> String {
  let base_schemas =
    tools_registry.all_core_tool_schemas_with_policy(fn(name) {
      tool_policy_allows_tool(tool_policy, name)
    })
  case mcp_client {
    Some(client) -> {
      case tool_policy_allows(tool_policy, UseMcp) {
        False -> "[" <> base_schemas <> "]"
        True -> {
          case mcp_client.list_tools(client) {
            Ok(tools) -> {
              let mcp_schemas =
                list.map(tools, fn(t) {
                  "{\"type\":\"function\",\"function\":{\"name\":\""
                  <> t.name
                  <> "\",\"description\":\""
                  <> t.description
                  <> "\",\"parameters\":"
                  <> t.input_schema
                  <> "}}"
                })
                |> string.join(",")
              case base_schemas, mcp_schemas {
                "", "" -> "[]"
                "", schemas -> "[" <> schemas <> "]"
                schemas, "" -> "[" <> schemas <> "]"
                schemas, mcp -> "[" <> schemas <> "," <> mcp <> "]"
              }
            }
            Error(err) -> {
              hermes_logger.failure("global", "mcp_list_tools_failed", err, [])
              "[" <> base_schemas <> "]"
            }
          }
        }
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

pub fn parse_response_usage(json_str: String) -> Int {
  let decoder = {
    use usage <- decode.field("usage", {
      use total_tokens <- decode.field("total_tokens", decode.int)
      decode.success(total_tokens)
    })
    decode.success(usage)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok(total) -> total
    Error(_) -> 0
  }
}

pub fn extract_delta_usage(json_str: String) -> Option(Int) {
  let decoder = {
    use usage <- decode.field("usage", {
      use total_tokens <- decode.field("total_tokens", decode.int)
      decode.success(total_tokens)
    })
    decode.success(usage)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok(total) -> Some(total)
    Error(_) -> None
  }
}

/// Parse a complete (non-streaming) OpenAI chat completion JSON response.
pub fn parse_completion_response(json_str: String) -> AgentResponse {
  let text_decoder = {
    use choices <- decode.field(
      "choices",
      decode.list({
        use message <- decode.field("message", {
          use content <- decode.field("content", decode.string)
          decode.success(content)
        })
        decode.success(message)
      }),
    )
    decode.success(choices)
  }

  let tool_decoder = {
    use choices <- decode.field(
      "choices",
      decode.list({
        use message <- decode.field("message", {
          use tool_calls <- decode.field(
            "tool_calls",
            decode.list(decode.dynamic),
          )
          decode.success(tool_calls)
        })
        decode.success(message)
      }),
    )
    decode.success(choices)
  }

  // Try to parse as tool calls first
  case json.parse(from: json_str, using: tool_decoder) {
    Ok([[first_dyn_call, ..] as dyn_calls, ..]) -> {
      let _ = first_dyn_call
      // Encode each dynamic value back to json for decode_tool_call
      let raw_json_values =
        list.map(dyn_calls, fn(dyn) {
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
    use choices <- decode.field(
      "choices",
      decode.list({
        use message <- decode.field("message", {
          use tool_calls <- decode.field(
            "tool_calls",
            decode.list({
              use id <- decode.field("id", decode.string)
              use function <- decode.field("function", {
                use name <- decode.field("name", decode.string)
                use arguments <- decode.field("arguments", decode.string)
                decode.success(#(name, arguments))
              })
              decode.success(ToolCall(
                id: id,
                name: function.0,
                arguments: function.1,
              ))
            }),
          )
          decode.success(tool_calls)
        })
        decode.success(message)
      }),
    )
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
    use choices <- decode.field(
      "choices",
      decode.list({
        use finish_reason <- decode.field("finish_reason", decode.string)
        decode.success(finish_reason)
      }),
    )
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
    use choices <- decode.field(
      "choices",
      decode.list({
        use delta <- decode.field("delta", {
          use content <- decode.field("content", decode.string)
          decode.success(content)
        })
        decode.success(delta)
      }),
    )
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([content, ..]) -> Ok(content)
    _ -> Error(Nil)
  }
}

fn decode_openai_delta_tool_calls(json_str: String) -> Bool {
  // If choices[0].delta has tool_calls, we're in an OpenAI tool call stream
  let decoder = {
    use choices <- decode.field(
      "choices",
      decode.list({
        use delta <- decode.field("delta", {
          use tool_calls <- decode.field(
            "tool_calls",
            decode.list(decode.dynamic),
          )
          decode.success(tool_calls)
        })
        decode.success(delta)
      }),
    )
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([[_first_tc, ..], ..]) -> True
    _ -> {
      // Check for Anthropic tool stream format
      let anthropic_start_decoder = {
        use block <- decode.field("content_block", {
          use type_ <- decode.field("type", decode.string)
          decode.success(type_)
        })
        decode.success(block)
      }
      let anthropic_delta_decoder = {
        use delta <- decode.field("delta", {
          use type_ <- decode.field("type", decode.string)
          decode.success(type_)
        })
        decode.success(delta)
      }

      case json.parse(from: json_str, using: anthropic_start_decoder) {
        Ok("tool_use") -> True
        _ ->
          case json.parse(from: json_str, using: anthropic_delta_decoder) {
            Ok("input_json_delta") -> True
            _ -> False
          }
      }
    }
  }
}

pub type PartialToolCall {
  PartialToolCall(id: String, name: String, arguments_acc: String)
}

pub type StreamAccumulator {
  StreamAccumulator(
    text: String,
    reasoning: String,
    tool_calls: Dict(Int, PartialToolCall),
    tokens: Option(Int),
  )
}

fn decode_anthropic_tool_call_delta(
  json_str: String,
) -> List(#(Int, PartialToolCall)) {
  let start_decoder = {
    use index <- decode.field("index", decode.int)
    use block <- decode.field("content_block", {
      use type_ <- decode.field("type", decode.string)
      use id <- decode.optional_field("id", "", decode.string)
      use name <- decode.optional_field("name", "", decode.string)
      decode.success(#(type_, id, name))
    })
    decode.success(#(index, block))
  }

  case json.parse(from: json_str, using: start_decoder) {
    Ok(#(index, #("tool_use", id, name))) -> [
      #(index, PartialToolCall(id: id, name: name, arguments_acc: "")),
    ]
    _ -> {
      let delta_decoder = {
        use index <- decode.field("index", decode.int)
        use delta <- decode.field("delta", {
          use type_ <- decode.field("type", decode.string)
          use partial_json <- decode.optional_field(
            "partial_json",
            "",
            decode.string,
          )
          decode.success(#(type_, partial_json))
        })
        decode.success(#(index, delta))
      }

      case json.parse(from: json_str, using: delta_decoder) {
        Ok(#(index, #("input_json_delta", partial_json))) -> [
          #(
            index,
            PartialToolCall(id: "", name: "", arguments_acc: partial_json),
          ),
        ]
        _ -> []
      }
    }
  }
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
    decode.success(#(
      index,
      PartialToolCall(id: id, name: name, arguments_acc: arguments),
    ))
  }
  let decoder = {
    use choices <- decode.field(
      "choices",
      decode.list({
        use delta <- decode.field("delta", {
          use tool_calls <- decode.field("tool_calls", decode.list(tc_decoder))
          decode.success(tool_calls)
        })
        decode.success(delta)
      }),
    )
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([tcs, ..]) -> tcs
    _ -> decode_anthropic_tool_call_delta(json_str)
  }
}

fn decode_openai_reasoning(json_str: String) -> Result(String, Nil) {
  let decoder = {
    use choices <- decode.field(
      "choices",
      decode.list({
        use delta <- decode.field("delta", {
          use reasoning <- decode.field("reasoning_content", decode.string)
          decode.success(reasoning)
        })
        decode.success(delta)
      }),
    )
    decode.success(choices)
  }
  case json.parse(from: json_str, using: decoder) {
    Ok([reasoning, ..]) -> Ok(reasoning)
    _ -> Error(Nil)
  }
}

/// Decode streaming delta text from an SSE JSON line.
/// Tries OpenAI delta format first, then Anthropic text format.
pub fn extract_delta_content(json_str: String) -> #(String, String) {
  let text = case decode_openai_delta(json_str) {
    Ok(t) -> t
    Error(_) -> {
      let anthropic_decoder = {
        use delta <- decode.field("delta", {
          use t <- decode.field("text", decode.string)
          decode.success(t)
        })
        decode.success(delta)
      }
      case json.parse(from: json_str, using: anthropic_decoder) {
        Ok(t) -> t
        Error(_) -> ""
      }
    }
  }

  let reasoning = case decode_openai_reasoning(json_str) {
    Ok(r) -> r
    Error(_) -> ""
  }

  #(text, reasoning)
}

// ─── Streaming Response Collector ─────────────────────────────────────────────

/// Streams an SSE response from the LLM, printing delta text to stdout
/// and accumulating the full content. Returns the full accumulated response.
pub fn stream_and_collect(
  req_id: hermes_client.ReqId,
  parser: LineParserState,
  accumulated: StreamAccumulator,
  on_delta: Option(fn(String) -> Nil),
  spinner: Option(process.Subject(kawaii_spinner.SpinnerMessage)),
) -> #(StreamAccumulator, Bool) {
  // Allow configuring timeout via env var for slow free-tier models (default: 300s)
  let timeout_ms = case constants.get_env("HERMES_STREAM_TIMEOUT_MS") {
    Some(val) ->
      case int.parse(val) {
        Ok(n) -> n
        Error(_) -> 300_000
      }
    None -> 300_000
  }
  case hermes_client.receive_stream_chunk(req_id, timeout_ms) {
    StreamStart(_) ->
      stream_and_collect(req_id, parser, accumulated, on_delta, spinner)

    StreamChunk(chunk) -> {
      case spinner {
        Some(s) -> kawaii_spinner.stop(s)
        None -> Nil
      }
      let #(lines, next_parser) = hermes_client.feed_chunk(parser, chunk)
      let #(new_acc, saw_tool_call) =
        list.fold(lines, #(accumulated, False), fn(state, line) {
          let #(acc, tc_seen) = state
          case hermes_client.parse_sse_line(line) {
            Some(json_str) -> {
              let #(text_delta, reasoning_delta) =
                extract_delta_content(json_str)

              case text_delta != "" {
                True -> {
                  case on_delta {
                    Some(handler) -> handler(text_delta)
                    None -> io.print(text_delta)
                  }
                }
                False -> Nil
              }

              case reasoning_delta != "" {
                True -> {
                  case on_delta {
                    // We don't send reasoning to handler to avoid confusing TUI, but we print it locally
                    Some(_) -> Nil
                    // Print reasoning in dim grey
                    None ->
                      io.print(
                        "\u{001b}[90m" <> reasoning_delta <> "\u{001b}[0m",
                      )
                  }
                }
                False -> Nil
              }

              let tcs = decode_delta_tool_calls(json_str)
              let new_tcs =
                list.fold(tcs, acc.tool_calls, fn(tc_dict, tc_tuple) {
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
                      dict.insert(
                        tc_dict,
                        index,
                        PartialToolCall(new_id, new_name, new_args),
                      )
                    }
                    Error(_) -> {
                      dict.insert(tc_dict, index, ptc)
                    }
                  }
                })
              let tc_seen_now = tcs != []
              let is_tool_call = decode_openai_delta_tool_calls(json_str)

              let usage_opt = case acc.tokens {
                Some(total) -> Some(total)
                None -> extract_delta_usage(json_str)
              }
              let updated_acc =
                StreamAccumulator(
                  text: acc.text <> text_delta,
                  reasoning: acc.reasoning <> reasoning_delta,
                  tool_calls: new_tcs,
                  tokens: usage_opt,
                )
              #(updated_acc, tc_seen || is_tool_call || tc_seen_now)
            }
            None -> #(acc, tc_seen)
          }
        })
      stream_and_collect(req_id, next_parser, new_acc, on_delta, None)
      |> fn(result) {
        let #(final_acc, final_tc) = result
        #(final_acc, final_tc || saw_tool_call)
      }
    }

    StreamEnd -> {
      case spinner {
        Some(s) -> kawaii_spinner.stop(s)
        None -> Nil
      }
      case on_delta {
        None -> io.println("")
        Some(_) -> Nil
      }
      #(accumulated, False)
    }

    StreamError(err) -> {
      case spinner {
        Some(s) -> kawaii_spinner.stop(s)
        None -> Nil
      }
      io.println("\n[Stream Error: " <> err <> "]")
      // Return error marker so agent_turn_loop knows it's an API failure
      #(
        StreamAccumulator(
          text: "__STREAM_ERROR__:" <> err,
          reasoning: "",
          tool_calls: dict.new(),
          tokens: None,
        ),
        False,
      )
    }

    StreamTimeout -> {
      case spinner {
        Some(s) -> kawaii_spinner.stop(s)
        None -> Nil
      }
      io.println("\n[Stream Timeout] — model may be down or key exhausted")
      #(
        StreamAccumulator(
          text: "__STREAM_ERROR__:timeout",
          reasoning: "",
          tool_calls: dict.new(),
          tokens: None,
        ),
        False,
      )
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
  memory_ctx: String,
) -> String {
  // Inject dynamic context
  let dynamic_context =
    context_engine.execute_all(context_engine.default_plugins())
  let final_system_prompt = case dynamic_context {
    "" -> system_prompt
    ctx -> system_prompt <> "\n\n" <> ctx
  }

  let final_system_prompt = case memory_ctx {
    "" -> final_system_prompt
    ctx -> final_system_prompt <> "\n\n<memory>\n" <> ctx <> "\n</memory>"
  }

  let system_msg =
    json.object([
      #("role", json.string("system")),
      #("content", json.string(final_system_prompt)),
    ])
    |> json.to_string

  // Sliding window: trim to newest 60 messages when history exceeds 80
  let window_size = 60
  let max_history = 80
  let trimmed_history = case list.length(history) > max_history {
    True -> list.take(history, window_size)
    False -> history
  }

  // Anthropic prompt caching: add cache_control marker to system + last message
  // when the provider supports it and there's enough context to benefit.
  let cache_backend = prompt_cache.detect_backend(
    case constants.get_env("HERMES_BASE_URL") {
      Some(u) -> u
      None -> "https://openrouter.ai/api/v1"
    },
  )
  let all_messages = case cache_backend.supports_cache_control {
    False -> [system_msg, ..trimmed_history]
    True -> {
      case list.length(trimmed_history) >= 3 {
        False -> [system_msg, ..trimmed_history]
        True -> {
          let system_with_cache =
            json.object([
              #("role", json.string("system")),
              #("content", json.string(final_system_prompt)),
              #("cache_control", json.object([#("type", json.string("ephemeral"))])),
            ])
            |> json.to_string
          [system_with_cache, ..trimmed_history]
        }
      }
    }
  }

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
    True -> "true,\"stream_options\":{\"include_usage\":true}"
    False -> "false"
  }
  <> "}"
}

// ─── Message History Builders ──────────────────────────────────────────────────

pub fn parse_markdown_images(text: String) -> List(json.Json) {
  case string.split(text, "![") {
    [first, ..rest] -> {
      let first_json = case first == "" {
        True -> []
        False -> [
          json.object([
            #("type", json.string("text")),
            #("text", json.string(first)),
          ]),
        ]
      }

      let rest_json =
        list.flat_map(rest, fn(chunk) {
          case string.split_once(chunk, "](") {
            Ok(#(_alt, after_bracket)) -> {
              case string.split_once(after_bracket, ")") {
                Ok(#(url, after_paren)) -> {
                  let img =
                    json.object([
                      #("type", json.string("image_url")),
                      #("image_url", json.object([#("url", json.string(url))])),
                    ])
                  case after_paren == "" {
                    True -> [img]
                    False -> [
                      img,
                      json.object([
                        #("type", json.string("text")),
                        #("text", json.string(after_paren)),
                      ]),
                    ]
                  }
                }
                Error(_) -> [
                  json.object([
                    #("type", json.string("text")),
                    #("text", json.string("![" <> chunk)),
                  ]),
                ]
              }
            }
            Error(_) -> [
              json.object([
                #("type", json.string("text")),
                #("text", json.string("![" <> chunk)),
              ]),
            ]
          }
        })

      list.append(first_json, rest_json)
    }
    [] -> []
  }
}

pub fn user_message(content: String) -> String {
  let has_image = string.contains(content, "![")
  let content_json = case has_image {
    True -> json.array(parse_markdown_images(content), of: fn(x) { x })
    False -> json.string(content)
  }

  json.object([
    #("role", json.string("user")),
    #("content", content_json),
  ])
  |> json.to_string
}

pub fn assistant_message(content: String) -> String {
  json.object([
    #("role", json.string("assistant")),
    #("content", json.string(content)),
  ])
  |> json.to_string
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
  ])
  |> json.to_string
}

pub fn tool_result_message(tool_call_id: String, result: String) -> String {
  json.object([
    #("role", json.string("tool")),
    #("tool_call_id", json.string(tool_call_id)),
    #("content", json.string(result)),
  ])
  |> json.to_string
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
      Error(
        "Budget exhausted after "
        <> int.to_string(api_call_count)
        <> " iterations",
      )
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

      let spinner = case quiet {
        False -> Some(kawaii_spinner.start("Thinking... "))
        True -> None
      }

      let mem_ctx = memory_context(state)

      let body =
        build_request_body(
          active_model2,
          state.system_prompt,
          list.reverse(state.history),
          all_tool_schemas_with_policy(state.mcp_client, state.tool_policy),
          True,
          mem_ctx,
        )

      let cache_backend = prompt_cache.detect_backend(state.base_url)
      let cache_headers = prompt_cache.cache_headers(cache_backend)
      let anthropic_headers = case cache_backend.supports_cache_control {
        True -> prompt_cache.anthropic_beta_headers()
        False -> []
      }
      let headers =
        list.append(
          list.append(cache_headers, anthropic_headers),
          [
            #("Authorization", "Bearer " <> state.api_key),
            #("Content-Type", "application/json"),
            #("Accept", "text/event-stream"),
          ],
        )

      let cb_allowed = case state.circuit_breaker {
        Some(cb) -> circuit_breaker_actor.check(cb, active_model2)
        None -> True
      }
      let tb_allowed = case state.token_budget {
        Some(tb) -> token_budget.check(tb)
        None -> True
      }

      case cb_allowed, tb_allowed {
        False, _ -> {
          case spinner {
            Some(s) -> kawaii_spinner.stop(s)
            None -> Nil
          }
          let err = "Circuit breaker blocked request to " <> active_model2 <> " due to consecutive failures."
          hermes_logger.failure(state.session_id, "llm_request_blocked", err, [
            #("model", active_model2),
          ])
          case quiet {
            False -> io.println("\n[" <> err <> "]")
            True -> Nil
          }
          Error(err)
        }
        _, False -> {
          case spinner {
            Some(s) -> kawaii_spinner.stop(s)
            None -> Nil
          }
          let err = "Token budget exhausted."
          hermes_logger.failure(state.session_id, "llm_request_blocked", err, [
            #("model", active_model2),
          ])
          case quiet {
            False -> io.println("\n[" <> err <> "]")
            True -> Nil
          }
          Error(err)
        }
        True, True -> {
          use span_ctx <- span.new("llm_stream_call", [
            #("model", active_model2),
            #("url", state.base_url),
          ])

          let req_res =
            hermes_client.stream_post_request(
              state.base_url <> "/chat/completions",
              headers,
              "application/json",
              body,
            )

          case req_res {
            Error(err) -> {
              let _ = case state.circuit_breaker {
                Some(cb) -> circuit_breaker_actor.record_failure(cb, active_model2)
                None -> Nil
              }
              span.set_error_message(span_ctx, "API request failed: " <> err)
              hermes_logger.failure(state.session_id, "llm_request_failed", err, [
                #("model", active_model2),
              ])
              case spinner {
                Some(s) -> kawaii_spinner.stop(s)
                None -> Nil
              }
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
              let initial_acc = StreamAccumulator("", "", dict.new(), None)
              let #(final_acc, _saw_tool_calls_in_stream) =
                stream_and_collect(
                  req_id,
                  hermes_client.new_line_parser(),
                  initial_acc,
                  on_delta,
                  spinner,
                )

              let response_trimmed = string.trim(final_acc.text)
              let stream_tokens = case final_acc.tokens {
                Some(t) -> t
                None -> {
                  let prompt_est = string.length(body) / 4
                  let completion_est = string.length(response_trimmed) / 4
                  prompt_est + completion_est
                }
              }
              let _ = case state.token_budget {
                Some(tb) -> token_budget.record(tb, stream_tokens)
                None -> Nil
              }
              let agent_resp = case dict.size(final_acc.tool_calls) > 0 {
                True -> {
                  let calls =
                    dict.values(final_acc.tool_calls)
                    |> list.map(fn(ptc) {
                      ToolCall(
                        id: ptc.id,
                        name: ptc.name,
                        arguments: ptc.arguments_acc,
                      )
                    })
                  let _ = case state.circuit_breaker {
                    Some(cb) -> circuit_breaker_actor.record_success(cb, active_model2)
                    None -> Nil
                  }
                  ToolCalls(calls)
                }
                False -> {
                  case response_trimmed {
                    "" -> {
                      let _ = case spinner {
                        Some(s) -> kawaii_spinner.stop(s)
                        None -> Nil
                      }
                      fetch_fallback_non_streaming(state, body)
                    }
                    text -> {
                      case string.starts_with(text, "__STREAM_ERROR__:") {
                        True -> {
                          let reason = string.drop_start(text, 17)
                          let _ = case state.circuit_breaker {
                            Some(cb) -> circuit_breaker_actor.record_failure(cb, active_model2)
                            None -> Nil
                          }
                          span.set_error_message(span_ctx, "Stream failed: " <> reason)
                          hermes_logger.failure(state.session_id, "llm_stream_failed", reason, [
                            #("model", active_model2),
                          ])
                          ErrorResponse("Stream failed: " <> reason)
                        }
                        False -> {
                          let _ = case state.circuit_breaker {
                            Some(cb) -> circuit_breaker_actor.record_success(cb, active_model2)
                            None -> Nil
                          }
                          FinalText(text)
                        }
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
                  io.println(
                    "\n🔧 Executing "
                    <> int.to_string(list.length(calls))
                    <> " tool call(s)...",
                  )
                }
              }

              let calls_msg = assistant_tool_calls_message(calls)
              let _ =
                state_actor.insert_message(
                  state.db_conn,
                  state.session_id,
                  "assistant",
                  "",
                  calls_msg,
                  int.to_float(system_time_ms()) /. 1000.0,
                )
              // Append the assistant's tool_calls message to history
              let history_with_assistant = [calls_msg, ..state.history]

              // Execute each tool and collect results
              let #(new_exec_env, new_history) =
                list.fold(
                  calls,
                  #(state.exec_env, history_with_assistant),
                  fn(acc, tc) {
                    let #(current_env, current_history) = acc
                    let #(next_env, result) =
                      dispatch_tool(
                        AgentState(..state, exec_env: current_env),
                        tc,
                        quiet,
                      )
                    case state.on_event {
                      Some(handler) -> handler(ToolComplete(tc.name, result))
                      None -> Nil
                    }
                    let tool_msg = tool_result_message(tc.id, result)
                    let _ =
                      state_actor.insert_message(
                        state.db_conn,
                        state.session_id,
                        "tool",
                        result,
                        tool_msg,
                        int.to_float(system_time_ms()) /. 1000.0,
                      )
                    #(next_env, [tool_msg, ..current_history])
                  },
                )

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
              let timestamp = int.to_float(system_time_ms()) /. 1000.0
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

              let new_history = [assistant_message(final_text), ..state.history]

              Ok(AgentState(..state, history: new_history))
            }

            // ── Error response path — classify and attempt model fallback ────
            // Inspired by lm-eval-harness per-error-type retry config:
            // auth errors advance immediately, timeouts retry then advance.
            ErrorResponse(reason) -> {
              hermes_logger.failure(state.session_id, "llm_response_failed", reason, [
                #("model", active_model2),
              ])
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
              let timestamp = int.to_float(system_time_ms()) /. 1000.0
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

              let new_history = [assistant_message(final_text), ..state.history]

              Ok(AgentState(..state, history: new_history))
            }
          }
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
  let cb_allowed = case state.circuit_breaker {
    Some(cb) -> circuit_breaker_actor.check(cb, state.model)
    None -> True
  }
  let tb_allowed = case state.token_budget {
    Some(tb) -> token_budget.check(tb)
    None -> True
  }

  case cb_allowed, tb_allowed {
    False, _ -> ErrorResponse("Circuit breaker blocked request to " <> state.model)
    _, False -> ErrorResponse("Token budget exhausted.")
    True, True -> {
      use span_ctx <- span.new("llm_sync_call", [
        #("model", state.model),
        #("url", state.base_url),
      ])

      // Build non-streaming body
      let mem_ctx = memory_context(state)

      let body =
        build_request_body(
          state.model,
          state.system_prompt,
          list.reverse(state.history),
          all_tool_schemas_with_policy(state.mcp_client, state.tool_policy),
          False,
          mem_ctx,
        )

      let headers = [
        #("Authorization", "Bearer " <> state.api_key),
        #("Content-Type", "application/json"),
      ]

      let res =
        hermes_client.post_request_with_retry(
          state.base_url <> "/chat/completions",
          headers,
          "application/json",
          body,
        )

      case res {
        Ok(response_json) -> {
          let _ = case state.token_budget {
            Some(tb) -> token_budget.record(tb, parse_response_usage(response_json))
            None -> Nil
          }
          let parsed = parse_completion_response(response_json)
          case parsed {
            ErrorResponse(err) -> {
              let _ = case state.circuit_breaker {
                Some(cb) -> circuit_breaker_actor.record_failure(cb, state.model)
                None -> Nil
              }
              span.set_error_message(span_ctx, "API request returned error: " <> err)
              parsed
            }
            _ -> {
              let _ = case state.circuit_breaker {
                Some(cb) -> circuit_breaker_actor.record_success(cb, state.model)
                None -> Nil
              }
              parsed
            }
          }
        }
            Error(err) -> {
          let _ = case state.circuit_breaker {
            Some(cb) -> circuit_breaker_actor.record_failure(cb, state.model)
            None -> Nil
              }
              span.set_error_message(span_ctx, "API request failed: " <> err)
              hermes_logger.failure(state.session_id, "llm_request_failed", err, [
                #("model", state.model),
              ])
              ErrorResponse(err)
        }
      }
    }
  }
}

// ─── Public Entry Point ────────────────────────────────────────────────────────

fn memory_context(state: AgentState) -> String {
  let backend = case constants.get_env("HERMES_MEMORY_BACKEND") {
    Some(value) -> string.lowercase(string.trim(value))
    None -> ""
  }

  let plugin = case backend {
    "honcho" -> Some(memory_plugin.honcho_adapter(state.api_key, "user-default"))
    "mem0" -> Some(memory_plugin.mem0_adapter(state.api_key, "user-default"))
    "supermemory" -> Some(memory_plugin.supermemory_adapter(state.api_key, "user-default"))
    "gleamdb" -> Some(memory_plugin.gleamdb_memory_adapter(state.db_conn))
    _ -> None
  }

  let plugin_ctx = case plugin {
    Some(memory) -> case memory.retrieve_context(state.session_id) {
      Ok(ctx) -> ctx
      Error(_) -> ""
    }
    None -> ""
  }

  let vector_ctx = case env_flag_enabled("HERMES_ENABLE_SEMANTIC_SEARCH") {
    False -> ""
    True -> {
      let store = vector_memory.new()
      let latest = case list.first(state.history) {
        Ok(msg) -> extract_text_from_msg(msg)
        Error(_) -> ""
      }
      case latest == "" {
        True -> ""
        False -> {
          let results =
            vector_memory.search(store, latest, state.api_key, limit: 3)
          case results {
            [] -> ""
            _ ->
              "Relevant past context (vector search):\n"
              <> vector_memory.format_results(results)
          }
        }
      }
    }
  }

  case plugin_ctx, vector_ctx {
    "", "" -> ""
    ctx, "" -> ctx
    "", vctx -> vctx
    ctx, vctx -> ctx <> "\n\n" <> vctx
  }
}

fn extract_text_from_msg(msg: String) -> String {
  let decoder = {
    use content <- decode.field("content", decode.string)
    decode.success(content)
  }
  case json.parse(from: msg, using: decoder) {
    Ok(content) -> content
    Error(_) -> ""
  }
}

pub fn compress_history(
  history: List(String),
  state: AgentState,
) -> Result(String, String) {
  let summary_model = "claude-3-haiku-20240307"

  let cb_allowed = case state.circuit_breaker {
    Some(cb) -> circuit_breaker_actor.check(cb, summary_model)
    None -> True
  }
  let tb_allowed = case state.token_budget {
    Some(tb) -> token_budget.check(tb)
    None -> True
  }

  case cb_allowed, tb_allowed {
    False, _ -> Error("Circuit breaker blocked compression request to " <> summary_model)
    _, False -> Error("Token budget exhausted.")
    True, True -> {
      use span_ctx <- span.new("llm_compress_call", [
        #("model", summary_model),
        #("url", state.base_url),
      ])

      let prompt =
        "Summarize the following conversation history concisely. Retain key facts, constraints, and instructions:\n\n"

      let user_msg =
        json.object([
          #("role", json.string("user")),
          #(
            "content",
            json.string(prompt <> string.join(list.reverse(history), "\n")),
          ),
        ])

      let body =
        json.object([
          #("model", json.string(summary_model)),
          #("messages", json.array([user_msg], of: fn(x) { x })),
          #("stream", json.bool(False)),
        ])
        |> json.to_string

      let headers = [
        #("Authorization", "Bearer " <> state.api_key),
        #("Content-Type", "application/json"),
      ]

      let res =
        hermes_client.post_request(
          state.base_url,
          headers,
          "application/json",
          body,
        )

      case res {
        Ok(json_resp) -> {
          let _ = case state.token_budget {
            Some(tb) -> token_budget.record(tb, parse_response_usage(json_resp))
            None -> Nil
          }
          let resp = parse_completion_response(json_resp)
          case resp {
            FinalText(text) -> {
              let _ = case state.circuit_breaker {
                Some(cb) -> circuit_breaker_actor.record_success(cb, summary_model)
                None -> Nil
              }
              Ok(text)
            }
            _ -> {
              let _ = case state.circuit_breaker {
                Some(cb) -> circuit_breaker_actor.record_failure(cb, summary_model)
                None -> Nil
              }
              span.set_error_message(span_ctx, "Failed to parse compression response")
              Error("Failed to parse compression response")
            }
          }
        }
        Error(err_str) -> {
          let _ = case state.circuit_breaker {
            Some(cb) -> circuit_breaker_actor.record_failure(cb, summary_model)
            None -> Nil
          }
          span.set_error_message(span_ctx, "Compression API request failed: " <> err_str)
          hermes_logger.failure(state.session_id, "llm_compression_failed", err_str, [
            #("model", summary_model),
          ])
          Error("Compression API request failed: " <> err_str)
        }
      }
    }
  }
}

/// Run a multi-turn conversation with the LLM, handling tool calls recursively.
pub fn run_conversation(
  state: AgentState,
  user_prompt: String,
) -> Result(AgentState, String) {
  use span_ctx <- span.new("run_conversation", [
    #("session_id", state.session_id),
    #("model", state.model),
  ])

  hermes_logger.info(
    state.session_id,
    "Starting run_conversation with user prompt length: "
      <> int.to_string(string.length(user_prompt)),
  )
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

  // Index user message into vector store for semantic search
  case env_flag_enabled("HERMES_ENABLE_SEMANTIC_SEARCH") {
    True -> {
      let store = vector_memory.new()
      let _ =
        vector_memory.add(store, user_prompt, state.session_id, state.api_key)
      Nil
    }
    False -> Nil
  }

  // Append user message to history
  let new_history = [user_message(user_prompt), ..state.history]

  // Compaction: use token-based thresholds from compaction module
  let compaction_config = compaction.config_from_env(fn(name) {
    case constants.get_env(name) {
      Some(v) -> Some(v)
      None -> None
    }
  })
  let history_tokens = compaction.estimate_messages_tokens(new_history)
  let compaction_tier = compaction.check_threshold(compaction_config, history_tokens)

  let compressed_history = case compaction_tier {
    compaction.NoCompaction -> new_history
    _ -> {
      hermes_logger.event("INFO", state.session_id, "compaction_triggered", [
        #("tier", case compaction_tier {
          compaction.SoftTrigger(_) -> "soft"
          compaction.HardTrigger(_) -> "hard"
          _ -> "none"
        }),
        #("tokens", int.to_string(history_tokens)),
        #("pct", int.to_string(compaction.context_usage_pct(compaction_config, history_tokens))),
      ])
      let to_keep = list.take(new_history, 40)
      let to_compress = list.drop(new_history, 40)
      case compress_history(to_compress, state) {
        Ok(summary) -> {
          let summary_msg =
            user_message("[Summary of older conversation]:\n" <> summary)
          list.append(to_keep, [summary_msg])
        }
        Error(err) -> {
          io.println("Compression error: " <> err)
          to_keep
        }
      }
    }
  }

  let new_state = AgentState(..state, history: compressed_history)

  let result = agent_turn_loop(new_state, 0)
  case result {
    Error(err) -> {
      span.set_error_message(span_ctx, err)
      hermes_logger.failure(state.session_id, "session_run_failed", err, [
        #("model", state.model),
      ])
      result
    }
    Ok(_) -> result
  }
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
  circuit_breaker: Option(circuit_breaker_actor.CircuitBreaker),
  token_budget: Option(token_budget.TokenBudget),
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
        router: Some(model_router.from_env()),
        circuit_breaker: circuit_breaker,
        token_budget: token_budget,
        tool_policy: default_tool_policy(),
      ))
    Error(_) -> Error("Failed to start iteration budget actor")
  }
}
