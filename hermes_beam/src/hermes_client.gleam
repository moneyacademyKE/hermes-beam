import gleam/option.{type Option, Some, None}
import gleam/string
import gleam/list
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process

/// Opaque request ID returned by stream_post_request.
/// Using Dynamic allows zero-cost wrapping of the Erlang httpc RequestId.
pub type ReqId = Dynamic

pub type LineParserState {
  LineParserState(
    buffer: String,
  )
}

pub type StreamMessage {
  StreamStart(headers: List(#(String, String)))
  StreamChunk(chunk: String)
  StreamEnd
  StreamError(reason: String)
  StreamTimeout
}

pub type DecodedHttpChunk {
  DecodedStart(headers: List(#(String, String)))
  DecodedStream(chunk: String)
  DecodedEnd
  DecodedError(reason: String)
  DecodedIgnored
}

pub fn new_line_parser() -> LineParserState {
  LineParserState(buffer: "")
}

pub fn feed_chunk(state: LineParserState, chunk: String) -> #(List(String), LineParserState) {
  let combined = state.buffer <> chunk
  let lines = string.split(combined, on: "\n")
  
  case list.reverse(lines) {
    [] -> #([], LineParserState(""))
    [incomplete, ..rest] -> {
      let complete_lines = list.reverse(rest)
      let clean_lines = list.map(complete_lines, fn(line) {
        case string.ends_with(line, "\r") {
          True -> string.drop_end(line, 1)
          False -> line
        }
      })
      #(clean_lines, LineParserState(incomplete))
    }
  }
}

pub fn parse_sse_line(line: String) -> Option(String) {
  let trimmed = string.trim(line)
  case string.starts_with(trimmed, "data:") {
    True -> {
      let content = string.trim(string.drop_start(trimmed, 5))
      case content {
        "[DONE]" -> None
        "" -> None
        _ -> Some(content)
      }
    }
    False -> None
  }
}

@external(erlang, "hermes_http", "post")
pub fn post_request(
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: String,
) -> Result(String, String)

/// Like post_request but with exponential backoff retry on 429/502/503.
/// Use this for non-streaming fallback calls to avoid failing on transient quota limits.
@external(erlang, "hermes_http", "post_with_retry")
pub fn post_request_with_retry(
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: String,
) -> Result(String, String)

@external(erlang, "hermes_http", "stream_post")
pub fn stream_post_request(
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: String,
) -> Result(Dynamic, String)

@external(erlang, "hermes_http", "decode_http_message")
fn decode_http_message(payload: Dynamic, req_id: Dynamic) -> DecodedHttpChunk

pub fn receive_stream_chunk(req_id: Dynamic, timeout_ms: Int) -> StreamMessage {
  let http_atom = atom.to_dynamic(atom.create("http"))
  let selector =
    process.new_selector()
    |> process.select_record(http_atom, 1, fn(payload) {
      decode_http_message(payload, req_id)
    })
  
  case process.selector_receive(selector, timeout_ms) {
    Ok(DecodedStart(headers)) -> StreamStart(headers)
    Ok(DecodedStream(chunk)) -> StreamChunk(chunk)
    Ok(DecodedEnd) -> StreamEnd
    Ok(DecodedError(reason)) -> StreamError(reason)
    Ok(DecodedIgnored) -> {
      receive_stream_chunk(req_id, timeout_ms)
    }
    Error(_) -> StreamTimeout
  }
}
