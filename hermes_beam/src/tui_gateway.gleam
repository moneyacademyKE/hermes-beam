import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import hermes_agent.{type AgentState}
import hermes_exec
import state_actor.{type StateActor}
import utils
import sqlight
import gleam/erlang/process
import gleamdb

@external(erlang, "erlang", "system_time")
fn system_time_ms() -> Int

pub type GatewayState {
  GatewayState(
    state_actor: StateActor,
    api_key: String,
    base_url: String,
    default_model: String,
    sessions: dict.Dict(String, AgentState),
    config: dict.Dict(String, String),
  )
}

pub type JsonRpcEnvelope {
  JsonRpcEnvelope(
    jsonrpc: String,
    method: String,
    id: Option(Dynamic),
    params: Option(Dynamic),
  )
}

fn envelope_decoder() {
  use jsonrpc <- decode.field("jsonrpc", decode.string)
  use method <- decode.field("method", decode.string)
  use id <- decode.optional_field("id", None, decode.optional(decode.dynamic))
  use params <- decode.optional_field("params", None, decode.optional(decode.dynamic))
  decode.success(JsonRpcEnvelope(jsonrpc, method, id, params))
}

pub type SessionResumeParams {
  SessionResumeParams(session_id: String)
}

fn session_resume_decoder() {
  use session_id <- decode.field("session_id", decode.string)
  decode.success(SessionResumeParams(session_id))
}

pub type PromptSubmitParams {
  PromptSubmitParams(session_id: String, text: String)
}

fn prompt_submit_decoder() {
  use session_id <- decode.field("session_id", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(PromptSubmitParams(session_id, text))
}

pub type ConfigGetParams {
  ConfigGetParams(key: String)
}

fn config_get_decoder() {
  use key <- decode.field("key", decode.string)
  decode.success(ConfigGetParams(key))
}

pub type ConfigSetParams {
  ConfigSetParams(key: String, value: String)
}

fn config_set_decoder() {
  use key <- decode.field("key", decode.string)
  use value <- decode.field("value", decode.string)
  decode.success(ConfigSetParams(key, value))
}

fn id_to_json(id: Option(Dynamic)) -> json.Json {
  case id {
    None -> json.null()
    Some(dyn) -> {
      case decode.run(dyn, decode.string) {
        Ok(s) -> json.string(s)
        Error(_) -> {
          case decode.run(dyn, decode.int) {
            Ok(i) -> json.int(i)
            Error(_) -> json.null()
          }
        }
      }
    }
  }
}

pub fn make_success_response(id: Option(Dynamic), result_val: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_to_json(id)),
    #("result", result_val),
  ])
  |> json.to_string
}

pub fn make_error_response(id: Option(Dynamic), code: Int, message: String) -> String {
  let err_obj = json.object([
    #("code", json.int(code)),
    #("message", json.string(message)),
  ])
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_to_json(id)),
    #("error", err_obj),
  ])
  |> json.to_string
}

fn write_stdout(msg: String) -> Nil {
  io.println(msg)
}

fn emit_event(session_id: String, event: hermes_agent.AgentEvent) -> Nil {
  let #(type_str, payload) = case event {
    hermes_agent.MessageDelta(content) -> {
      #("message.delta", json.object([#("content", json.string(content))]))
    }
    hermes_agent.ToolStart(name, arguments) -> {
      #("tool.start", json.object([
        #("tool_name", json.string(name)),
        #("arguments", json.string(arguments)),
      ]))
    }
    hermes_agent.ToolComplete(name, result) -> {
      #("tool.complete", json.object([
        #("tool_name", json.string(name)),
        #("result", json.string(result)),
      ]))
    }
    hermes_agent.MessageComplete(content) -> {
      #("message.complete", json.object([#("content", json.string(content))]))
    }
  }
  
  let notification = json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("event")),
    #(
      "params",
      json.object([
        #("type", json.string(type_str)),
        #("session_id", json.string(session_id)),
        #("payload", payload),
      ]),
    ),
  ])
  |> json.to_string
  
  write_stdout(notification)
}

fn dispatch_method(
  state: GatewayState,
  id: Option(Dynamic),
  method: String,
  params_opt: Option(Dynamic),
) -> GatewayState {
  case method {
    "session.create" -> {
      let session_id = hermes_exec.generate_uuid()
      let timestamp = int.to_float(system_time_ms()) /. 1000.0
      case state_actor.create_session(
        state.state_actor,
        session_id,
        "tui",
        state.default_model,
        "You are a helpful assistant.",
        timestamp,
      ) {
        Ok(_) -> {
          let res_json = json.object([#("session_id", json.string(session_id))])
          let resp = make_success_response(id, res_json)
          write_stdout(resp)
        }
        Error(err) -> {
          let msg = case err {
            sqlight.SqlightError(message: msg, ..) -> msg
          }
          let resp = make_error_response(id, -32603, "Internal error: " <> msg)
          write_stdout(resp)
        }
      }
      state
    }

    "session.resume" -> {
      case params_opt {
        Some(params_dyn) -> {
          case decode.run(params_dyn, session_resume_decoder()) {
            Ok(params) -> {
              let cwd = case state_actor.get_session_cwd(state.state_actor, params.session_id) {
                Ok(c) if c != "" -> c
                _ -> hermes_exec.get_temp_dir()
              }
              let res_json = json.object([
                #("session_id", json.string(params.session_id)),
                #("cwd", json.string(cwd)),
              ])
              let resp = make_success_response(id, res_json)
              write_stdout(resp)
            }
            Error(_) -> {
              let resp = make_error_response(id, -32602, "Invalid params")
              write_stdout(resp)
            }
          }
        }
        None -> {
          let resp = make_error_response(id, -32602, "Invalid params")
          write_stdout(resp)
        }
      }
      state
    }

    "session.list" -> {
      case state_actor.list_sessions(state.state_actor) {
        Ok(ids) -> {
          let res_json = json.array(ids, of: json.string)
          let resp = make_success_response(id, res_json)
          write_stdout(resp)
        }
        Error(err) -> {
          let msg = case err {
            sqlight.SqlightError(message: msg, ..) -> msg
          }
          let resp = make_error_response(id, -32603, "Internal error: " <> msg)
          write_stdout(resp)
        }
      }
      state
    }

    "config.get" -> {
      case params_opt {
        Some(params_dyn) -> {
          case decode.run(params_dyn, config_get_decoder()) {
            Ok(params) -> {
              let val = case dict.get(state.config, params.key) {
                Ok(v) -> json.string(v)
                Error(_) -> json.null()
              }
              let res_json = json.object([#("value", val)])
              let resp = make_success_response(id, res_json)
              write_stdout(resp)
            }
            Error(_) -> {
              let resp = make_error_response(id, -32602, "Invalid params")
              write_stdout(resp)
            }
          }
        }
        None -> {
          let resp = make_error_response(id, -32602, "Invalid params")
          write_stdout(resp)
        }
      }
      state
    }

    "config.set" -> {
      case params_opt {
        Some(params_dyn) -> {
          case decode.run(params_dyn, config_set_decoder()) {
            Ok(params) -> {
              let new_config = dict.insert(state.config, params.key, params.value)
              let next_state = GatewayState(..state, config: new_config)
              let resp = make_success_response(id, json.object([]))
              write_stdout(resp)
              next_state
            }
            Error(_) -> {
              let resp = make_error_response(id, -32602, "Invalid params")
              write_stdout(resp)
              state
            }
          }
        }
        None -> {
          let resp = make_error_response(id, -32602, "Invalid params")
          write_stdout(resp)
          state
        }
      }
    }

    "prompt.submit" -> {
      case params_opt {
        Some(params_dyn) -> {
          case decode.run(params_dyn, prompt_submit_decoder()) {
            Ok(params) -> {
              // Retrieve or construct agent state
              let #(agent_state, next_state) = case dict.get(state.sessions, params.session_id) {
                Ok(existing_agent) -> {
                  #(existing_agent, state)
                }
                Error(_) -> {
                  let cwd = case state_actor.get_session_cwd(state.state_actor, params.session_id) {
                    Ok(c) if c != "" -> c
                    _ -> hermes_exec.get_temp_dir()
                  }
                  let exec_env = hermes_exec.new_terminal_env(cwd, 120_000, [])
                  let exec_env = hermes_exec.init_session(exec_env)
                  
                  let sys_prompt = dict.get(state.config, "system_prompt")
                    |> result.unwrap("You are a helpful assistant with access to shell tools.")
                  
                  case hermes_agent.new_agent_state(
                    params.session_id,
                    state.default_model,
                    cwd,
                    state.state_actor,
                    exec_env,
                    state.api_key,
                    state.base_url,
                    sys_prompt,
                    90,
                    option.None,
                  ) {
                    Ok(new_agent) -> {
                      let new_sessions = dict.insert(state.sessions, params.session_id, new_agent)
                      #(new_agent, GatewayState(..state, sessions: new_sessions))
                    }
                    Error(_) -> {
                      panic as "Failed to create agent state"
                    }
                  }
                }
              }

              let state_with_handler = hermes_agent.with_event_handler(agent_state, fn(event) {
                emit_event(params.session_id, event)
              })

              case hermes_agent.run_conversation(state_with_handler, params.text) {
                Ok(final_agent_state) -> {
                  let stored_agent_state = hermes_agent.AgentState(..final_agent_state, on_event: None)
                  let new_sessions = dict.insert(next_state.sessions, params.session_id, stored_agent_state)
                  let next_state = GatewayState(..next_state, sessions: new_sessions)
                  let resp = make_success_response(id, json.object([]))
                  write_stdout(resp)
                  next_state
                }
                Error(err) -> {
                  let resp = make_error_response(id, -32603, "Agent error: " <> err)
                  write_stdout(resp)
                  next_state
                }
              }
            }
            Error(_) -> {
              let resp = make_error_response(id, -32602, "Invalid params")
              write_stdout(resp)
              state
            }
          }
        }
        None -> {
          let resp = make_error_response(id, -32602, "Invalid params")
          write_stdout(resp)
          state
        }
      }
    }

    _ -> {
      let resp = make_error_response(id, -32601, "Method not found")
      write_stdout(resp)
      state
    }
  }
}

fn handle_line(state: GatewayState, line: String) -> GatewayState {
  let envelope_res = json.parse(from: line, using: envelope_decoder())
  case envelope_res {
    Error(_) -> {
      let resp = make_error_response(None, -32700, "Parse error")
      write_stdout(resp)
      state
    }
    Ok(envelope) -> {
      case envelope.jsonrpc {
        "2.0" -> {
          dispatch_method(state, envelope.id, envelope.method, envelope.params)
        }
        _ -> {
          let resp = make_error_response(envelope.id, -32600, "Invalid Request")
          write_stdout(resp)
          state
        }
      }
    }
  }
}

pub type TuiMessage {
  StdinLine(String)
  StdinClosed
  StateBroadcast(gleamdb.Datom)
}

pub fn start_tui_server(
  state_actor: StateActor,
  api_key: String,
  base_url: String,
  default_model: String,
  broadcast_subj: Option(process.Subject(gleamdb.Datom)),
) -> Nil {
  let config = dict.from_list([
    #("model", default_model),
    #("system_prompt", "You are a helpful assistant with access to shell tools."),
  ])
  let initial_state = GatewayState(
    state_actor: state_actor,
    api_key: api_key,
    base_url: base_url,
    default_model: default_model,
    sessions: dict.new(),
    config: config,
  )

  let subj: process.Subject(TuiMessage) = process.new_subject()
  
  // Stdin reader process
  let _ = process.spawn(fn() {
    stdin_loop(subj)
  })

  // Hook up state broadcast if available
  case broadcast_subj {
    Some(bsubj) -> {
      let _ = process.spawn(fn() {
        broadcast_loop(bsubj, subj)
      })
      Nil
    }
    None -> Nil
  }

  server_loop(initial_state, subj)
}

fn broadcast_loop(bsubj: process.Subject(gleamdb.Datom), main_subj: process.Subject(TuiMessage)) -> Nil {
  case process.receive(bsubj, 600_000) {
    Ok(datom) -> {
      process.send(main_subj, StateBroadcast(datom))
      broadcast_loop(bsubj, main_subj)
    }
    Error(_) -> broadcast_loop(bsubj, main_subj)
  }
}

fn server_loop(state: GatewayState, subj: process.Subject(TuiMessage)) -> Nil {
  case process.receive(subj, 600_000) {
    Ok(StdinLine(line)) -> {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> server_loop(state, subj)
        _ -> {
          let next_state = handle_line(state, trimmed)
          server_loop(next_state, subj)
        }
      }
    }
    Ok(StateBroadcast(datom)) -> {
      // Forward side effects or intents to the frontend via JSON-RPC Notification
      let notif = json.object([
        #("jsonrpc", json.string("2.0")),
        #("method", json.string("hermes.broadcast")),
        #("params", json.object([
          #("entity", json.string(datom.entity)),
          #("attribute", json.string(datom.attribute)),
          #("value", json.string(datom.value)),
        ]))
      ])
      write_stdout(json.to_string(notif))
      server_loop(state, subj)
    }
    Ok(StdinClosed) -> Nil
    Error(_) -> server_loop(state, subj)
  }
}

fn stdin_loop(subj: process.Subject(TuiMessage)) -> Nil {
  case utils.read_line("") {
    Ok(line) -> {
      process.send(subj, StdinLine(line))
      stdin_loop(subj)
    }
    Error(_) -> {
      process.send(subj, StdinClosed)
      Nil
    }
  }
}
