import gleam/json
import hermes_client

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
