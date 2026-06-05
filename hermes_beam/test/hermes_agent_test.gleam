import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import hermes_agent.{
  ToolCall,
  all_tool_schemas,
  assistant_message,
  assistant_tool_calls_message,
  build_request_body,
  parse_finish_reason,
  parse_tool_calls_from_json,
  tool_result_message,
  user_message,
}
import hermes_client

// ─── Tool Call JSON Parsing ────────────────────────────────────────────────────

pub fn parse_tool_calls_empty_test() {
  // Plain text response should return empty list
  let j = "{\"choices\":[{\"message\":{\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}"
  let calls = parse_tool_calls_from_json(j)
  let assert [] = calls
}

pub fn parse_tool_calls_single_test() {
  let j =
    "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"call_abc\",\"type\":\"function\",\"function\":{\"name\":\"run_command\",\"arguments\":\"{\\\"command\\\":\\\"ls -la\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
  let calls = parse_tool_calls_from_json(j)
  let assert [tc] = calls
  let assert "call_abc" = tc.id
  let assert "run_command" = tc.name
  let assert "{\"command\":\"ls -la\"}" = tc.arguments
}

pub fn parse_tool_calls_multiple_test() {
  let j =
    "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"run_command\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}},{\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"/etc/hosts\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
  let calls = parse_tool_calls_from_json(j)
  let assert [tc1, tc2] = calls
  let assert "call_1" = tc1.id
  let assert "run_command" = tc1.name
  let assert "call_2" = tc2.id
  let assert "read_file" = tc2.name
}

pub fn parse_tool_calls_malformed_test() {
  // Non-JSON / unexpected shape should return empty list without crashing
  let assert [] = parse_tool_calls_from_json("")
  let assert [] = parse_tool_calls_from_json("{}")
  let assert [] = parse_tool_calls_from_json("null")
}

// ─── Finish Reason Parsing ─────────────────────────────────────────────────────

pub fn parse_finish_reason_stop_test() {
  let j = "{\"choices\":[{\"message\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}"
  let assert "stop" = parse_finish_reason(j)
}

pub fn parse_finish_reason_tool_calls_test() {
  let j =
    "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[]},\"finish_reason\":\"tool_calls\"}]}"
  let assert "tool_calls" = parse_finish_reason(j)
}

pub fn parse_finish_reason_fallback_test() {
  // Malformed → falls back to "stop"
  let assert "stop" = parse_finish_reason("{}")
}

// ─── Message Builder Tests ─────────────────────────────────────────────────────

pub fn user_message_test() {
  let msg = user_message("hello")
  let json_str = json.to_string(msg)
  let assert True = string.contains(json_str, "\"role\":\"user\"")
  let assert True = string.contains(json_str, "\"content\":\"hello\"")
}

pub fn assistant_message_test() {
  let msg = assistant_message("world")
  let json_str = json.to_string(msg)
  let assert True = string.contains(json_str, "\"role\":\"assistant\"")
  let assert True = string.contains(json_str, "\"content\":\"world\"")
}

pub fn assistant_tool_calls_message_test() {
  let tc =
    ToolCall(id: "call_1", name: "run_command", arguments: "{\"command\":\"ls\"}")
  let msg = assistant_tool_calls_message([tc])
  let json_str = json.to_string(msg)
  let assert True = string.contains(json_str, "\"role\":\"assistant\"")
  let assert True = string.contains(json_str, "\"tool_calls\"")
  let assert True = string.contains(json_str, "run_command")
}

pub fn tool_result_message_test() {
  let msg = tool_result_message("call_1", "{\"output\":\"file1.txt\"}")
  let json_str = json.to_string(msg)
  let assert True = string.contains(json_str, "\"role\":\"tool\"")
  let assert True = string.contains(json_str, "\"tool_call_id\":\"call_1\"")
}

// ─── Tool Schemas ──────────────────────────────────────────────────────────────

pub fn all_tool_schemas_valid_json_test() {
  let schemas = all_tool_schemas()
  // Should parse as a JSON array without error
  let result = json.parse(from: schemas, using: decode.list(decode.dynamic))
  let assert Ok(items) = result
  // Should have 3 tools: run_command, write_file, read_file
  let assert 3 = list.length(items)
}

pub fn tool_schemas_contain_required_names_test() {
  let schemas = all_tool_schemas()
  let assert True = string.contains(schemas, "\"run_command\"")
  let assert True = string.contains(schemas, "\"write_file\"")
  let assert True = string.contains(schemas, "\"read_file\"")
}

// ─── Request Body Builder ──────────────────────────────────────────────────────

pub fn build_request_body_contains_model_test() {
  let body =
    build_request_body(
      "meta-llama/llama-3-8b-instruct",
      "You are helpful.",
      [],
      "[]",
      False,
    )
  // Should be valid JSON
  let result = json.parse(from: body, using: decode.dynamic)
  let assert Ok(_) = result
  // Should contain model name
  let assert True = string.contains(body, "meta-llama/llama-3-8b-instruct")
}

pub fn build_request_body_includes_system_test() {
  let body = build_request_body("gpt-4o", "Be precise.", [], "[]", True)
  let assert True = string.contains(body, "Be precise.")
  let assert True = string.contains(body, "\"stream\":true")
}

pub fn build_request_body_with_history_test() {
  let history = [user_message("What is 2+2?"), assistant_message("4")]
  let body = build_request_body("gpt-4o", "You are helpful.", history, "[]", False)
  let assert True = string.contains(body, "What is 2+2?")
  let assert True = string.contains(body, "\"stream\":false")
}

pub fn build_request_body_non_stream_test() {
  let body = build_request_body("claude-3", "sys", [], "[]", False)
  let assert True = string.contains(body, "\"stream\":false")
}

// ─── SSE Parsing Integration ───────────────────────────────────────────────────

pub fn sse_line_with_tool_call_delta_test() {
  // Tool call delta lines with no content still appear as data: lines
  let line =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0}]},\"finish_reason\":null}]}"
  let result = hermes_client.parse_sse_line(line)
  // It IS a data: line so we get Some(json_str)
  let assert Some(_json_str) = result
}

pub fn sse_line_done_terminates_test() {
  let assert None = hermes_client.parse_sse_line("data: [DONE]")
}

pub fn sse_line_non_data_ignored_test() {
  let assert None = hermes_client.parse_sse_line("event: message_start")
  let assert None = hermes_client.parse_sse_line(": comment")
  let assert None = hermes_client.parse_sse_line("")
}

// ─── Tool Call Struct Fields ───────────────────────────────────────────────────

pub fn tool_call_struct_access_test() {
  let tc = ToolCall(id: "abc", name: "run_command", arguments: "{}")
  let assert "abc" = tc.id
  let assert "run_command" = tc.name
  let assert "{}" = tc.arguments
}
