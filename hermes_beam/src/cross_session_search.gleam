import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/json
import gleam/list
import gleam/order.{Gt, Lt}
import gleam/string
import hermes_agent
import hermes_client
import hermes_state
import semantic_search
import sqlight

// FFI to get unix timestamp
@external(erlang, "erlang", "system_time")
fn ffi_system_time(unit: atom.Atom) -> Int

fn system_time_seconds() -> Float {
  let sec = ffi_system_time(atom.create("second"))
  let float_sec = int_to_float(sec)
  float_sec
}

@external(erlang, "erlang", "float")
fn int_to_float(x: Int) -> Float

fn extract_message_info(msg: String) -> String {
  let decoder = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(role, content))
  }
  case json.parse(from: msg, using: decoder) {
    Ok(#(role, content)) -> role <> ": " <> content
    Error(_) -> msg
  }
}

pub fn save_session_summary_and_embedding(
  session_id: String,
  history: List(String),
  base_url: String,
  api_key: String,
  model: String,
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  case history {
    [] -> Ok(Nil)
    _ -> {
      let transcript =
        list.map(history, extract_message_info)
        |> string.join(with: "\n")

      let summary_prompt =
        "Summarize this agent session transcript in one paragraph, capturing key user goals, achieved steps, and decisions: \n\n"
        <> transcript

      let body =
        json.object([
          #("model", json.string(model)),
          #(
            "messages",
            json.array(
              [
                json.object([
                  #("role", json.string("user")),
                  #("content", json.string(summary_prompt)),
                ]),
              ],
              of: fn(x) { x },
            ),
          ),
          #("stream", json.bool(False)),
        ])
        |> json.to_string

      let headers = [
        #("Authorization", "Bearer " <> api_key),
        #("Content-Type", "application/json"),
      ]

      case hermes_client.post_request(base_url, headers, "application/json", body) {
        Ok(json_resp) -> {
          case hermes_agent.parse_completion_response(json_resp) {
            hermes_agent.FinalText(summary) -> {
              case semantic_search.generate_embedding(summary, api_key) {
                Ok(embedding) -> {
                  let now = system_time_seconds()
                  case
                    hermes_state.save_session_embedding(
                      conn,
                      session_id,
                      summary,
                      embedding,
                      now,
                    )
                  {
                    Ok(_) -> Ok(Nil)
                    Error(e) ->
                      Error("Failed to save session embedding: " <> e.message)
                  }
                }
                Error(e) -> Error("Failed to generate embedding: " <> e)
              }
            }
            _ -> Error("Failed to parse completion summary")
          }
        }
        Error(err) -> Error("LLM request failed: " <> err)
      }
    }
  }
}

pub fn get_semantic_context(
  query: String,
  api_key: String,
  conn: sqlight.Connection,
  top_k: Int,
) -> Result(String, String) {
  case semantic_search.generate_embedding(query, api_key) {
    Ok(query_emb) -> {
      case hermes_state.get_all_session_embeddings(conn) {
        Ok(sessions) -> {
          let scored =
            list.map(sessions, fn(s) {
              let score = semantic_search.cosine_similarity(query_emb, s.embedding)
              #(s, score)
            })
            // Sort descending by score
            |> list.sort(fn(a, b) {
              case a.1 >. b.1 {
                True -> Lt
                False -> Gt
              }
            })
            |> list.take(top_k)

          let formatted =
            list.map(scored, fn(pair) {
              let s = pair.0
              "- [Session: " <> s.session_id <> "]: " <> s.summary
            })
            |> string.join(with: "\n")

          case formatted {
            "" -> Ok("")
            _ ->
              Ok(
                "Related historical context from past sessions:\n"
                <> formatted
                <> "\n",
              )
          }
        }
        Error(e) -> Error("Failed to retrieve embeddings: " <> e.message)
      }
    }
    Error(e) -> Error("Failed to generate embedding for query: " <> e)
  }
}


