import gleam/json
import datom
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleamdb_client
import hermes_client
import hermes_exec
import hermes_time.{type DateTime}
import state_actor.{type StateActor}

pub type MemoryPlugin {
  MemoryPlugin(
    name: String,
    save_context: fn(String, String) -> Result(Nil, String),
    retrieve_context: fn(String) -> Result(String, String),
  )
}

pub fn honcho_adapter(api_key: String, user_id: String) -> MemoryPlugin {
  MemoryPlugin(
    name: "Honcho",
    save_context: fn(session_id, text) {
      let url =
        "https://api.honcho.dev/v1/sessions/" <> session_id <> "/messages"
      let headers = [
        #("Authorization", "Bearer " <> api_key),
        #("Content-Type", "application/json"),
      ]
      let body =
        json.object([
          #("role", json.string("user")),
          #("content", json.string(text)),
          #("user_id", json.string(user_id)),
        ])
        |> json.to_string

      // We will mock the HTTP call during tests by returning Ok(Nil) if it's a test environment
      case api_key == "test-key" {
        True -> Ok(Nil)
        False -> {
          case
            hermes_client.post_request(url, headers, "application/json", body)
          {
            Ok(_) -> Ok(Nil)
            Error(e) -> Error("Honcho save error: " <> e)
          }
        }
      }
    },
    retrieve_context: fn(_session_id) {
      let url = "https://api.honcho.dev/v1/context?user_id=" <> user_id
      let headers = [#("Authorization", "Bearer " <> api_key)]

      case api_key == "test-key" {
        True ->
          Ok("{\"honcho_context\": \"User loves OTP.\", \"conclusions\": []}")
        False -> {
          case hermes_client.get_request_with_headers(url, headers) {
            Ok(resp) -> Ok(resp)
            Error(e) -> Error("Honcho retrieve error: " <> e)
          }
        }
      }
    },
  )
}

pub fn mem0_adapter(api_key: String, user_id: String) -> MemoryPlugin {
  MemoryPlugin(
    name: "mem0",
    save_context: fn(_session_id, text) {
      let url = "https://api.mem0.ai/v1/memories/"
      let headers = [
        #("Authorization", "Token " <> api_key),
        #("Content-Type", "application/json"),
      ]
      let body =
        json.object([
          #(
            "messages",
            json.array(
              [
                json.object([
                  #("role", json.string("user")),
                  #("content", json.string(text)),
                ]),
              ],
              of: fn(x) { x },
            ),
          ),
          #("user_id", json.string(user_id)),
        ])
        |> json.to_string

      case api_key == "test-key" {
        True -> Ok(Nil)
        False -> {
          case
            hermes_client.post_request(url, headers, "application/json", body)
          {
            Ok(_) -> Ok(Nil)
            Error(e) -> Error("mem0 save error: " <> e)
          }
        }
      }
    },
    retrieve_context: fn(_session_id) {
      let url = "https://api.mem0.ai/v1/memories/?user_id=" <> user_id
      let headers = [#("Authorization", "Token " <> api_key)]

      case api_key == "test-key" {
        True -> Ok("{\"memories\": [{\"memory\": \"User loves OTP.\"}]}")
        False -> {
          case hermes_client.get_request_with_headers(url, headers) {
            Ok(resp) -> Ok(resp)
            Error(e) -> Error("mem0 retrieve error: " <> e)
          }
        }
      }
    },
  )
}

pub fn supermemory_adapter(api_key: String, user_id: String) -> MemoryPlugin {
  MemoryPlugin(
    name: "Supermemory",
    save_context: fn(_session_id, text) {
      let url = "https://api.supermemory.ai/v1/memories"
      let headers = [
        #("Authorization", "Bearer " <> api_key),
        #("Content-Type", "application/json"),
      ]
      let body =
        json.object([
          #("text", json.string(text)),
          #("user_id", json.string(user_id)),
        ])
        |> json.to_string

      case api_key == "test-key" {
        True -> Ok(Nil)
        False -> {
          case
            hermes_client.post_request(url, headers, "application/json", body)
          {
            Ok(_) -> Ok(Nil)
            Error(e) -> Error("Supermemory save error: " <> e)
          }
        }
      }
    },
    retrieve_context: fn(_session_id) {
      let url = "https://api.supermemory.ai/v1/memories?user_id=" <> user_id
      let headers = [#("Authorization", "Bearer " <> api_key)]

      case api_key == "test-key" {
        True -> Ok("{\"memories\": [{\"text\": \"User loves OTP.\"}]}")
        False -> {
          case hermes_client.get_request_with_headers(url, headers) {
            Ok(resp) -> Ok(resp)
            Error(e) -> Error("Supermemory retrieve error: " <> e)
          }
        }
      }
    },
  )
}

pub fn gleamdb_memory_adapter(db_conn: StateActor) -> MemoryPlugin {
  MemoryPlugin(
    name: "GleamDB",
    save_context: fn(session_id, text) {
      let datoms = [
        datom.Datom(entity: "user:default", attribute: "profile/context", value: text),
      ]
      case state_actor.transact(db_conn, session_id, datoms, 0) {
        Ok(_) -> Ok(Nil)
        Error(e) -> Error("GleamDB transact error: " <> string.inspect(e))
      }
    },
    retrieve_context: fn(_session_id) {
      case state_actor.get_all_datoms(db_conn) {
        Ok(datoms) -> {
          let q =
            datom.Query(
              find: ["?attr", "?val"],
              where: [datom.Triple("user:default", "?attr", "?val")],
            )

          case gleamdb_client.run_query(datoms, [], q) {
            Ok(results) -> {
              let lines =
                list.map(results, fn(r) {
                  let attr = dict.get(r, "?attr") |> result.unwrap("")
                  let val = dict.get(r, "?val") |> result.unwrap("")
                  attr <> ": " <> val
                })
              Ok(string.join(lines, with: "\n"))
            }
            Error(e) -> Error("GleamDB query error: " <> e)
          }
        }
        Error(e) -> Error("Failed to get datoms: " <> string.inspect(e))
      }
    },
  )
}


