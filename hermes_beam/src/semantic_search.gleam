import gleam/dynamic/decode
import gleam/json
import gleam/list
import hermes_client

@external(erlang, "math", "sqrt")
pub fn sqrt(x: Float) -> Float

pub fn dot_product(v1: List(Float), v2: List(Float)) -> Float {
  list.zip(v1, v2)
  |> list.fold(0.0, fn(acc, pair) { acc +. pair.0 *. pair.1 })
}

pub fn magnitude(v: List(Float)) -> Float {
  let sq_sum = list.fold(v, 0.0, fn(acc, x) { acc +. x *. x })
  sqrt(sq_sum)
}

pub fn cosine_similarity(v1: List(Float), v2: List(Float)) -> Float {
  let denom = magnitude(v1) *. magnitude(v2)
  case denom == 0.0 {
    True -> 0.0
    False -> dot_product(v1, v2) /. denom
  }
}

pub fn generate_embedding(
  text: String,
  api_key: String,
) -> Result(List(Float), String) {
  let body =
    json.object([
      #("model", json.string("text-embedding-3-small")),
      #("input", json.string(text)),
    ])
    |> json.to_string

  let headers = [
    #("Authorization", "Bearer " <> api_key),
    #("Content-Type", "application/json"),
  ]

  let url = "https://api.openai.com/v1/embeddings"

  let decoder = {
    use data <- decode.field(
      "data",
      decode.list({
        use embedding <- decode.field("embedding", decode.list(decode.float))
        decode.success(embedding)
      }),
    )
    decode.success(data)
  }

  case hermes_client.post_request(url, headers, "application/json", body) {
    Ok(json_resp) -> {
      case json.parse(from: json_resp, using: decoder) {
        Ok([embedding, ..]) -> Ok(embedding)
        _ -> Error("Failed to parse embedding")
      }
    }
    Error(err) -> Error("Embedding API request failed: " <> err)
  }
}
