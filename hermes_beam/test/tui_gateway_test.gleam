import gleam/option.{None, Some}
import gleam/json
import gleam/dynamic/decode
import tui_gateway

pub fn id_to_json_test() {
  // Test dynamic id decoding/encoding in make_success_response / id_to_json
  let envelope_json = "{\"jsonrpc\": \"2.0\", \"method\": \"session.create\", \"id\": 123}"
  let decoder = {
    use jsonrpc <- decode.field("jsonrpc", decode.string)
    use method <- decode.field("method", decode.string)
    use id <- decode.optional_field("id", None, decode.optional(decode.dynamic))
    use params <- decode.optional_field("params", None, decode.optional(decode.dynamic))
    decode.success(#(jsonrpc, method, id, params))
  }
  
  let assert Ok(#("2.0", "session.create", Some(id_dyn), None)) = 
    json.parse(from: envelope_json, using: decoder)
    
  // Verify making success response preserves numeric ID
  let resp = tui_gateway.make_success_response(Some(id_dyn), json.object([]))
  let assert "{\"jsonrpc\":\"2.0\",\"id\":123,\"result\":{}}" = resp
}

pub fn make_error_response_test() {
  let resp = tui_gateway.make_error_response(None, -32601, "Method not found")
  let assert "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}" = resp
}

pub fn envelope_parsing_test() {
  let req = "{\"jsonrpc\": \"2.0\", \"method\": \"prompt.submit\", \"params\": {\"session_id\": \"sess_1\", \"text\": \"hello\"}}"
  let decoder = {
    use jsonrpc <- decode.field("jsonrpc", decode.string)
    use method <- decode.field("method", decode.string)
    use id <- decode.optional_field("id", None, decode.optional(decode.dynamic))
    use params <- decode.optional_field("params", None, decode.optional(decode.dynamic))
    decode.success(#(jsonrpc, method, id, params))
  }
  
  let assert Ok(#("2.0", "prompt.submit", None, Some(params_dyn))) =
    json.parse(from: req, using: decoder)
    
  // Test prompt submit decoder on params
  let prompt_decoder = {
    use session_id <- decode.field("session_id", decode.string)
    use text <- decode.field("text", decode.string)
    decode.success(#(session_id, text))
  }
  let assert Ok(#("sess_1", "hello")) = decode.run(params_dyn, prompt_decoder)
}
