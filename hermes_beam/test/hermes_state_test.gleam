import gleam/list
import hermes_state
import sqlight

pub fn state_db_workflow_test() {
  // 1. Connect to an in-memory SQLite DB
  let assert Ok(conn) = hermes_state.connect(":memory:")

  // 2. Setup the schema
  let assert Ok(Nil) = hermes_state.init_schema(conn)

  // 3. Create a session
  let assert Ok(Nil) =
    hermes_state.create_session(
      conn,
      "session-123",
      "test-suite",
      "gpt-4o",
      "You are a helpful assistant.",
      1_717_000_000.0,
    )

  // 4. Update CWD
  let assert Ok(Nil) =
    hermes_state.update_session_cwd(conn, "session-123", "/workspace/test")

  // 5. End session
  let assert Ok(Nil) =
    hermes_state.end_session(conn, "session-123", "completed", 1_717_005_000.0)

  // 6. Reopen session
  let assert Ok(Nil) = hermes_state.reopen_session(conn, "session-123")

  // 7. Insert message logs (FTS triggers will index these automatically)
  let assert Ok(Nil) =
    hermes_state.insert_message(
      conn,
      "session-123",
      "user",
      "Hello agent, please find the bug in code_execution_tool.py",
      "{\"role\":\"user\"}",
      1_717_001_000.0,
    )
  let assert Ok(Nil) =
    hermes_state.insert_message(
      conn,
      "session-123",
      "assistant",
      "I have analyzed the file and resolved the bug.",
      "{\"role\":\"assistant\"}",
      1_717_002_000.0,
    )

  // 8. Perform FTS5 MATCH query search
  let assert Ok(matches) =
    hermes_state.search_messages(conn, "code_execution_tool")

  let assert 1 = list.length(matches)
  let assert Ok(first_match) = list.first(matches)
  let assert "session-123" = first_match.session_id
  let assert "user" = first_match.role
  let assert "Hello agent, please find the bug in code_execution_tool.py" =
    first_match.content

  // Clean close
  let _ = sqlight.close(conn)
  Nil
}
