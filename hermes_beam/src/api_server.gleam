import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Post}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string_tree
import hermes_agent
import hermes_exec
import mist
import state_actor.{type StateActor}
import wisp
import wisp/wisp_mist
import circuit_breaker_actor

pub fn start_server(
  db_conn: StateActor,
  api_key: String,
  base_url: String,
  port: Int,
) -> Result(Nil, String) {
  let secret_key_base = wisp.random_string(64)
  let assert Ok(cb) = circuit_breaker_actor.start(5, 30)
  let handler = handle_request(_, db_conn, api_key, base_url, cb)

  io.println("Starting API Server on http://localhost:" <> int.to_string(port))

  let assert Ok(_) =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
  Ok(Nil)
}

fn handle_request(
  req: wisp.Request,
  db_conn: StateActor,
  api_key: String,
  base_url: String,
  cb: circuit_breaker_actor.CircuitBreaker,
) -> wisp.Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  case req.method, wisp.path_segments(req) {
    Post, ["v1", "chat", "completions"] -> {
      handle_chat_completion(req, db_conn, api_key, base_url, cb)
    }
    _, _ -> wisp.not_found()
  }
}

fn handle_chat_completion(
  req: wisp.Request,
  db_conn: StateActor,
  api_key: String,
  base_url: String,
  cb: circuit_breaker_actor.CircuitBreaker,
) -> wisp.Response {
  // Read request body as JSON
  use body_json <- wisp.require_json(req)

  // Extract the latest message content from {"messages": [{"role": "user", "content": "..."}]}
  let prompt = case extract_last_message(body_json) {
    Ok(content) -> content
    Error(_) -> "Hello"
  }

  let cwd = hermes_exec.get_temp_dir()
  let exec_env = hermes_exec.new_terminal_env(cwd, 120_000, [])
  let agent_res =
    hermes_agent.new_agent_state(
      "api_session_" <> hermes_exec.generate_uuid(),
      "gpt-4o-mini",
      cwd,
      db_conn,
      exec_env,
      api_key,
      base_url,
      "You are a helpful assistant responding via the OpenAI-compatible API.",
      15,
      None,
      Some(cb),
      None,
    )

  case agent_res {
    Ok(agent_state) -> {
      case hermes_agent.run_conversation(agent_state, prompt) {
        Ok(new_state) -> {
          // The new state history has the assistant's final response at the head
          let content = case list.first(new_state.history) {
            Ok(msg) -> extract_content_from_history_msg(msg)
            Error(_) -> ""
          }
          let resp_body =
            json.object([
              #(
                "choices",
                json.array(
                  [
                    json.object([
                      #(
                        "message",
                        json.object([
                          #("role", json.string("assistant")),
                          #("content", json.string(content)),
                        ]),
                      ),
                    ]),
                  ],
                  fn(x) { x },
                ),
              ),
            ])
          wisp.json_response(json.to_string(resp_body), 200)
        }
        Error(err) -> {
          let err_body =
            json.object([
              #("error", json.object([#("message", json.string(err))])),
            ])
          wisp.json_response(json.to_string(err_body), 500)
        }
      }
    }
    Error(err) -> {
      let err_body =
        json.object([#("error", json.object([#("message", json.string(err))]))])
      wisp.json_response(json.to_string(err_body), 500)
    }
  }
}

fn extract_last_message(body: dynamic.Dynamic) -> Result(String, String) {
  let decoder = {
    use messages <- decode.field(
      "messages",
      decode.list({
        use content <- decode.field("content", decode.string)
        decode.success(content)
      }),
    )
    decode.success(messages)
  }
  let _json_str = string_tree.from_string("{\"messages\":[]}")
  // unused mock
  case decode.run(body, decoder) {
    Ok(messages) -> {
      case list.last(messages) {
        Ok(content) -> Ok(content)
        Error(_) -> Error("Empty List")
      }
    }
    Error(_) -> Error("Decode error")
  }
}

fn extract_content_from_history_msg(msg: String) -> String {
  let decoder = {
    use content <- decode.field("content", decode.string)
    decode.success(content)
  }
  case json.parse(from: msg, using: decoder) {
    Ok(content) -> content
    Error(_) -> msg
  }
}
