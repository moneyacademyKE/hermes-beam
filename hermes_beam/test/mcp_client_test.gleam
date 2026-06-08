import gleam/list
import gleam/string
import gleeunit/should
import qcheck

// A pure version of the buffer logic used in mcp_client
fn pure_process_buffer(buffer: String, acc: List(String)) -> #(String, List(String)) {
  case string.split_once(buffer, "\n") {
    Ok(#(line, rest)) -> {
      pure_process_buffer(rest, list.append(acc, [line]))
    }
    Error(_) -> #(buffer, acc)
  }
}

// Helper to simulate receiving fragments over a stream
fn simulate_stream(fragments: List(String), buffer: String, acc: List(String)) -> #(String, List(String)) {
  case fragments {
    [] -> #(buffer, acc)
    [frag, ..rest] -> {
      let #(new_buffer, new_acc) = pure_process_buffer(buffer <> frag, acc)
      simulate_stream(rest, new_buffer, new_acc)
    }
  }
}

pub fn buffer_reconstitution_property_test() {
  // Generate random lists of "messages" that are newline terminated
  let _message_generator = qcheck.string()
  
  // Property: For any list of fragments, if we concatenate them and process, 
  // it should yield the exact same extracted lines as processing them chunk by chunk,
  // demonstrating that fragmentation boundaries do not violate data integrity (immutability of stream).
  use fragments <- qcheck.given(
    qcheck.list_from(qcheck.string())
  )

  let full_string = string.concat(fragments)
  let #(final_buf1, lines1) = pure_process_buffer(full_string, [])
  let #(final_buf2, lines2) = simulate_stream(fragments, "", [])

  should.equal(final_buf1, final_buf2)
  should.equal(lines1, lines2)
}
