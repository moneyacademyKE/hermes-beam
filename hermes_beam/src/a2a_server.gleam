import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import hermes_agent
import hermes_exec
import mist
import state_actor.{type StateActor}
import wisp
import wisp/wisp_mist

pub type A2AAgentCard {
  A2AAgentCard(
    name: String,
    description: String,
    url: String,
    version: String,
    capabilities: List(String),
    skills: List(String),
  )
}

pub fn default_agent_card(base_url: String) -> A2AAgentCard {
  A2AAgentCard(
    name: "Hermes BEAM Agent",
    description: "Autonomous AI agent with OTP-supervised execution",
    url: base_url,
    version: "2.0.0",
    capabilities: ["streaming", "pushNotifications", "stateTransition"],
    skills: ["coding", "research", "automation"],
  )
}

pub fn agent_card_to_json(card: A2AAgentCard) -> String {
  json.object([
    #("name", json.string(card.name)),
    #("description", json.string(card.description)),
    #("url", json.string(card.url)),
    #("version", json.string(card.version)),
    #("capabilities", json.object([
      #("streaming", json.bool(True)),
      #("pushNotifications", json.bool(False)),
      #("stateTransition", json.bool(True)),
    ])),
    #("skills", json.array(
      card.skills,
      of: fn(s) {
        json.object([
          #("name", json.string(s)),
          #("description", json.string("Agent capability: " <> s)),
        ])
      },
    )),
    #("defaultInputModes", json.array(["application/json", "text/plain"], of: fn(m) { json.string(m) })),
    #("defaultOutputModes", json.array(["application/json", "text/plain"], of: fn(m) { json.string(m) })),
  ])
  |> json.to_string
}

pub fn start_a2a_server(
  db_conn: StateActor,
  api_key: String,
  llm_base_url: String,
  port: Int,
) -> Result(Nil, String) {
  let secret_key_base = wisp.random_string(64)
  let card = default_agent_card("http://localhost:" <> int.to_string(port))
  let handler = handle_a2a_request(_, db_conn, api_key, llm_base_url, card)

  io.println("Starting A2A Server on http://localhost:" <> int.to_string(port))
  io.println("  Agent Card: GET /.well-known/agent.json")
  io.println("  JSON-RPC: POST / (message/send, tasks/get, tasks/cancel)")

  let assert Ok(_) =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
  Ok(Nil)
}

fn handle_a2a_request(
  req: wisp.Request,
  db_conn: StateActor,
  api_key: String,
  llm_base_url: String,
  card: A2AAgentCard,
) -> wisp.Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  case req.method, wisp.path_segments(req) {
    Get, [".well-known", "agent.json"] -> {
      wisp.json_response(agent_card_to_json(card), 200)
    }

    Get, ["a2a", "agent.json"] -> {
      wisp.json_response(agent_card_to_json(card), 200)
    }

    Post, [] -> {
      handle_jsonrpc(req, db_conn, api_key, llm_base_url)
    }

    Post, ["a2a"] -> {
      handle_jsonrpc(req, db_conn, api_key, llm_base_url)
    }

    _, _ -> wisp.not_found()
  }
}

fn handle_jsonrpc(
  req: wisp.Request,
  db_conn: StateActor,
  api_key: String,
  llm_base_url: String,
) -> wisp.Response {
  use body <- wisp.require_json(req)

  case parse_jsonrpc_request(body) {
    Ok(rpc_req) -> {
      case rpc_req.method {
        "message/send" ->
          handle_message_send(rpc_req, body, db_conn, api_key, llm_base_url)
        "message/stream" ->
          handle_message_send(rpc_req, body, db_conn, api_key, llm_base_url)
        "tasks/get" ->
          handle_tasks_get(rpc_req)
        "tasks/cancel" ->
          handle_tasks_cancel(rpc_req)
        "tasks/list" ->
          handle_tasks_list(rpc_req)
        _ ->
          jsonrpc_error(rpc_req.id, -32601, "Method not found: " <> rpc_req.method)
      }
    }
    Error(reason) ->
      jsonrpc_error("unknown", -32700, "Parse error: " <> reason)
  }
}

type JsonRpcRequest {
  JsonRpcRequest(
    id: String,
    method: String,
    params: dynamic.Dynamic,
  )
}

fn parse_jsonrpc_request(body: dynamic.Dynamic) -> Result(JsonRpcRequest, String) {
  let decoder = {
    use id <- decode.field("id", decode.dynamic)
    use method <- decode.field("method", decode.string)
    use params <- decode.optional_field("params", dynamic.nil(), decode.dynamic)
    decode.success(JsonRpcRequest(
      id: dynamic_to_string(id),
      method: method,
      params: params,
    ))
  }
  case decode.run(body, decoder) {
    Ok(req) -> Ok(req)
    Error(err) -> Error(string.inspect(err))
  }
}

fn handle_message_send(
  rpc_req: JsonRpcRequest,
  body: dynamic.Dynamic,
  db_conn: StateActor,
  api_key: String,
  llm_base_url: String,
) -> wisp.Response {
  let message_decoder = {
    use message <- decode.field("message", {
      use role <- decode.field("role", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(#(role, content))
    })
    decode.success(message)
  }

  case decode.run(body, message_decoder) {
    Ok(#(role, content)) -> {
      let task_id = "a2a_" <> hermes_exec.generate_uuid()
      let cwd = hermes_exec.get_temp_dir()
      let exec_env = hermes_exec.new_terminal_env(cwd, 120_000, [])

      let agent_res =
        hermes_agent.new_agent_state(
          task_id,
          "gpt-4o-mini",
          cwd,
          db_conn,
          exec_env,
          api_key,
          llm_base_url,
          "You are an A2A agent. Respond concisely.",
          15,
          None,
          None,
          None,
        )

      case agent_res {
        Ok(agent_state) -> {
          case hermes_agent.run_conversation(agent_state, content) {
            Ok(new_state) -> {
              let response_content = case list.first(new_state.history) {
                Ok(msg) -> extract_content(msg)
                Error(_) -> ""
              }
              let result =
                json.object([
                  #("jsonrpc", json.string("2.0")),
                  #("id", json.string(rpc_req.id)),
                  #("result", json.object([
                    #("task_id", json.string(task_id)),
                    #("state", json.string("completed")),
                    #("message", json.object([
                      #("role", json.string("agent")),
                      #("content", json.string(response_content)),
                    ])),
                  ])),
                ])
                |> json.to_string
              wisp.json_response(result, 200)
            }
            Error(err) ->
              jsonrpc_error(rpc_req.id, -32000, "Agent error: " <> err)
          }
        }
        Error(err) ->
          jsonrpc_error(rpc_req.id, -32000, "Init error: " <> err)
      }
    }
    Error(_) -> {
      let simple_prompt = extract_text_param(rpc_req.params)
      case simple_prompt {
        "" -> jsonrpc_error(rpc_req.id, -32602, "Missing message content")
        prompt -> {
          let task_id = "a2a_" <> hermes_exec.generate_uuid()
          let result =
            json.object([
              #("jsonrpc", json.string("2.0")),
              #("id", json.string(rpc_req.id)),
              #("result", json.object([
                #("task_id", json.string(task_id)),
                #("state", json.string("submitted")),
              ])),
            ])
            |> json.to_string
          wisp.json_response(result, 200)
        }
      }
    }
  }
}

fn handle_tasks_get(rpc_req: JsonRpcRequest) -> wisp.Response {
  let result =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string(rpc_req.id)),
      #("result", json.object([
        #("state", json.string("completed")),
        #("message", json.object([
          #("role", json.string("agent")),
          #("content", json.string("Task retrieval via A2A — task store not persisted yet")),
        ])),
      ])),
    ])
    |> json.to_string
  wisp.json_response(result, 200)
}

fn handle_tasks_cancel(rpc_req: JsonRpcRequest) -> wisp.Response {
  let result =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string(rpc_req.id)),
      #("result", json.object([
        #("state", json.string("canceled")),
      ])),
    ])
    |> json.to_string
  wisp.json_response(result, 200)
}

fn handle_tasks_list(rpc_req: JsonRpcRequest) -> wisp.Response {
  let result =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string(rpc_req.id)),
      #("result", json.object([
        #("tasks", json.array([], of: fn(x) { x })),
      ])),
    ])
    |> json.to_string
  wisp.json_response(result, 200)
}

fn jsonrpc_error(id: String, code: Int, message: String) -> wisp.Response {
  let result =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string(id)),
      #("error", json.object([
        #("code", json.int(code)),
        #("message", json.string(message)),
      ])),
    ])
    |> json.to_string
  wisp.json_response(result, 200)
}

fn dynamic_to_string(d: dynamic.Dynamic) -> String {
  case decode.run(d, decode.string) {
    Ok(s) -> s
    Error(_) ->
      case decode.run(d, decode.int) {
        Ok(n) -> int.to_string(n)
        Error(_) -> "unknown"
      }
  }
}

fn extract_content(msg: String) -> String {
  let decoder = {
    use content <- decode.field("content", decode.string)
    decode.success(content)
  }
  case json.parse(from: msg, using: decoder) {
    Ok(content) -> content
    Error(_) -> msg
  }
}

fn extract_text_param(params: dynamic.Dynamic) -> String {
  let decoder = {
    use text <- decode.field("text", decode.string)
    decode.success(text)
  }
  case decode.run(params, decoder) {
    Ok(text) -> text
    Error(_) -> ""
  }
}
