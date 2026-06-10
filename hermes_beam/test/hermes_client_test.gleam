import gleam/option.{None, Some}
import hermes_client.{feed_chunk, new_line_parser, parse_sse_line}

pub fn feed_chunk_test() {
  let parser = new_line_parser()

  // 1. Partial line
  let #(lines, parser) = feed_chunk(parser, "hello")
  let assert [] = lines
  let assert "hello" = parser.buffer

  // 2. Complete the line and start a new one
  let #(lines, parser) = feed_chunk(parser, " world\nsecond line\r\nthi")
  let assert ["hello world", "second line"] = lines
  let assert "thi" = parser.buffer

  // 3. Complete remaining line
  let #(lines, parser) = feed_chunk(parser, "rd line\n")
  let assert ["third line"] = lines
  let assert "" = parser.buffer
}

pub fn parse_sse_line_test() {
  // 1. Standard line
  let assert Some("{\"content\": \"hello\"}") =
    parse_sse_line("data: {\"content\": \"hello\"}")

  // 2. Spaces/tabs trimming
  let assert Some("xyz") = parse_sse_line("  data:   xyz  ")

  // 3. DONE boundary
  let assert None = parse_sse_line("data: [DONE]")

  // 4. Non-data line
  let assert None = parse_sse_line("event: ping")
}
