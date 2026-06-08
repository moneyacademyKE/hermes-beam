import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/dict.{type Dict}
import hermes_exec

pub type McpTool {
  McpTool(name: String, description: String, input_schema: String)
}

@external(erlang, "json", "encode")
fn encode_json(data: Dynamic) -> String

pub type JsonRpcResponse {
  JsonRpcResponse(id: Int, result: Option(Dynamic), error: Option(Dynamic))
}

pub type JsonRpcNotification {
  JsonRpcNotification(method: String, params: Option(Dynamic))
}

fn rpc_response_decoder() {
  use id <- decode.field("id", decode.int)
  use res <- decode.optional_field("result", None, decode.optional(decode.dynamic))
  use err <- decode.optional_field("error", None, decode.optional(decode.dynamic))
  decode.success(JsonRpcResponse(id, res, err))
}

fn rpc_notification_decoder() {
  use method <- decode.field("method", decode.string)
  use params <- decode.optional_field("params", None, decode.optional(decode.dynamic))
  decode.success(JsonRpcNotification(method, params))
}

pub type Request {
  Initialize(reply: Subject(Result(Nil, String)))
  ListTools(reply: Subject(Result(List(McpTool), String)))
  CallTool(name: String, arguments: String, reply: Subject(Result(String, String)))
  Stop
}

pub type Message {
  UserRequest(Request)
  PortData(String)
  PortExit(Int)
}

pub type State {
  State(
    port: Dynamic,
    buffer: String,
    next_id: Int,
    pending: Dict(Int, Subject(Result(Dynamic, String))),
    on_notification: Option(Subject(JsonRpcNotification))
  )
}

pub type McpClient = Subject(Message)

@external(erlang, "hermes_exec_ffi", "decode_port_message")
fn decode_port_message(msg: Dynamic) -> hermes_exec.PortMessage

pub fn start(cmd: String, on_notification: Option(Subject(JsonRpcNotification))) -> Result(McpClient, String) {
  case hermes_exec.spawn_port(cmd) {
    Ok(port) -> {
      let client_subj = process.new_subject()
      let _ = process.spawn(fn() {
        let _ = process.spawn(fn() {
          let selector = process.new_selector()
            |> process.select_other(fn(m) { decode_port_message(m) })
          forward_loop(selector, client_subj)
        })
        
        loop(State(port: port, buffer: "", next_id: 1, pending: dict.new(), on_notification: on_notification), client_subj)
      })
      Ok(client_subj)
    }
    Error(err) -> Error(err)
  }
}

fn forward_loop(selector: process.Selector(hermes_exec.PortMessage), target: Subject(Message)) -> Nil {
  case process.selector_receive(selector, 600_000) {
    Ok(hermes_exec.PortData(data)) -> {
      process.send(target, PortData(data))
      forward_loop(selector, target)
    }
    Ok(hermes_exec.PortExit(status)) -> {
      process.send(target, PortExit(status))
    }
    _ -> {
      forward_loop(selector, target)
    }
  }
}

fn handle_json_line(state: State, line: String) -> State {
  case json.parse(from: line, using: rpc_response_decoder()) {
    Ok(resp) -> {
      case dict.get(state.pending, resp.id) {
        Ok(subj) -> {
          let res = case resp.error {
            Some(err) -> Error(string.inspect(err))
            None -> case resp.result {
              Some(dyn) -> Ok(dyn)
              None -> Error("No result or error")
            }
          }
          process.send(subj, res)
          State(..state, pending: dict.delete(state.pending, resp.id))
        }
        Error(_) -> state
      }
    }
    Error(_) -> {
      case json.parse(from: line, using: rpc_notification_decoder()) {
        Ok(notif) -> {
          case state.on_notification {
            Some(subj) -> process.send(subj, notif)
            None -> Nil
          }
          state
        }
        Error(_) -> state
      }
    }
  }
}
fn process_buffer(state: State) -> State {
  case string.split_once(state.buffer, "\n") {
    Ok(#(line, rest)) -> {
      let next_state = handle_json_line(state, line)
      process_buffer(State(..next_state, buffer: rest))
    }
    Error(_) -> state
  }
}

fn send_rpc(state: State, method: String, params: json.Json, subj: Subject(Result(Dynamic, String))) -> State {
  let id = state.next_id
  let payload = json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string(method)),
    #("params", params)
  ])
  let msg = json.to_string(payload) <> "\n"
  
  let _ = hermes_exec.send_input(state.port, msg)
  State(..state, next_id: id + 1, pending: dict.insert(state.pending, id, subj))
}

fn loop(state: State, subj: Subject(Message)) -> Nil {
  let selector = process.new_selector()
    |> process.select(subj)
    
  case process.selector_receive(selector, 600_000) {
    Ok(UserRequest(Stop)) -> {
      hermes_exec.kill_port_process(state.port)
      hermes_exec.close_port(state.port)
      Nil
    }
    Ok(UserRequest(Initialize(reply))) -> {
      let params = json.object([
        #("protocolVersion", json.string("2024-11-05")),
        #("capabilities", json.object([])),
        #("clientInfo", json.object([
          #("name", json.string("hermes_beam")),
          #("version", json.string("1.0.0"))
        ]))
      ])
      let wrap_subj = process.new_subject()
      let next_state = send_rpc(state, "initialize", params, wrap_subj)
      let _ = process.spawn(fn() {
        let res = case process.receive(wrap_subj, 5000) {
          Ok(Ok(_)) -> Ok(Nil)
          Ok(Error(e)) -> Error(e)
          Error(_) -> Error("Timeout")
        }
        process.send(reply, res)
      })
      loop(next_state, subj)
    }
    Ok(UserRequest(ListTools(reply))) -> {
      let wrap_subj = process.new_subject()
      let next_state = send_rpc(state, "tools/list", json.object([]), wrap_subj)
      let _ = process.spawn(fn() {
        let res = case process.receive(wrap_subj, 5000) {
          Ok(Ok(dyn)) -> {
            // Very simplified tool decoding
            let tool_decoder = {
              use name <- decode.field("name", decode.string)
              use desc <- decode.optional_field("description", "", decode.string)
              use schema_dyn <- decode.field("inputSchema", decode.dynamic)
              // We just stringify the schema since we pass it to the agent
              let schema_str = encode_json(schema_dyn)
              decode.success(McpTool(name, desc, schema_str))
            }
            let list_decoder = {
              use tools <- decode.field("tools", decode.list(tool_decoder))
              decode.success(tools)
            }
            case decode.run(dyn, list_decoder) {
              Ok(tools) -> Ok(tools)
              Error(e) -> Error(string.inspect(e))
            }
          }
          Ok(Error(e)) -> Error(e)
          Error(_) -> Error("Timeout")
        }
        process.send(reply, res)
      })
      loop(next_state, subj)
    }
    Ok(UserRequest(CallTool(name, args_str, reply))) -> {
      let _args_json = case json.parse(args_str, decode.dynamic) {
        Ok(_dyn) -> {
          // Convert dynamic back to json object is tricky, we'll just pass a string if it fails
          // But since the API expects an object, we can just use the raw JSON string if we do manual JSON building.
          // For simplicity we will build the raw JSON string manually for the whole RPC
          json.object([]) // placeholder
        }
        Error(_) -> json.object([])
      }
      // Actually we must inject the raw JSON string for args.
      let id = state.next_id
      let msg = "{\"jsonrpc\":\"2.0\",\"id\":" <> int.to_string(id) <> ",\"method\":\"tools/call\",\"params\":{\"name\":\"" <> name <> "\",\"arguments\":" <> args_str <> "}}\n"
      let _ = hermes_exec.send_input(state.port, msg)
      
      let wrap_subj = process.new_subject()
      let next_state = State(..state, next_id: id + 1, pending: dict.insert(state.pending, id, wrap_subj))
      
      let _ = process.spawn(fn() {
        let res = case process.receive(wrap_subj, 60_000) {
          Ok(Ok(dyn)) -> Ok(string.inspect(dyn))
          Ok(Error(e)) -> Error(e)
          Error(_) -> Error("Timeout")
        }
        process.send(reply, res)
      })
      loop(next_state, subj)
    }
    Ok(PortData(data)) -> {
      let new_buffer = state.buffer <> data
      let next_state = process_buffer(State(..state, buffer: new_buffer))
      loop(next_state, subj)
    }
    Ok(PortExit(_status)) -> {
      Nil
    }
    Error(_) -> {
      loop(state, subj)
    }
  }
}

pub fn initialize(client: McpClient) -> Result(Nil, String) {
  let subj = process.new_subject()
  process.send(client, UserRequest(Initialize(subj)))
  case process.receive(subj, 5000) {
    Ok(res) -> res
    Error(_) -> Error("Timeout")
  }
}

pub fn list_tools(client: McpClient) -> Result(List(McpTool), String) {
  let subj = process.new_subject()
  process.send(client, UserRequest(ListTools(subj)))
  case process.receive(subj, 5000) {
    Ok(res) -> res
    Error(_) -> Error("Timeout")
  }
}

pub fn call_tool(client: McpClient, name: String, args: String) -> Result(String, String) {
  let subj = process.new_subject()
  process.send(client, UserRequest(CallTool(name, args, subj)))
  case process.receive(subj, 65_000) {
    Ok(res) -> res
    Error(_) -> Error("Timeout")
  }
}

pub fn stop(client: McpClient) -> Nil {
  process.send(client, UserRequest(Stop))
}
