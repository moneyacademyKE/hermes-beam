import datom
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

pub fn session_isolation_test() {
  let assert Ok(conn) = hermes_state.connect(":memory:")
  let assert Ok(Nil) = hermes_state.init_schema(conn)

  // 1. Save global rules to fallback 'datoms' table
  let global_datom = datom.Datom("rule/global-1", "permission", "admin")
  let assert Ok(Nil) = hermes_state.save_session_datoms(conn, "global", [global_datom], 0)

  // 2. Save session-A specific datoms
  let datom_a = datom.Datom("session:session-A", "val", "A")
  let assert Ok(Nil) = hermes_state.save_session_datoms(conn, "session-A", [datom_a], 0)

  // 3. Save session-B specific datoms
  let datom_b = datom.Datom("session:session-B", "val", "B")
  let assert Ok(Nil) = hermes_state.save_session_datoms(conn, "session-B", [datom_b], 0)

  // 4. Retrieve session-A datoms (should contain A and global, but not B)
  let assert Ok(res_a) = hermes_state.get_session_datoms(conn, "session-A")
  let has_a = list.any(res_a, fn(d) { d.entity == "session:session-A" })
  let has_global = list.any(res_a, fn(d) { d.entity == "rule/global-1" })
  let has_b = list.any(res_a, fn(d) { d.entity == "session:session-B" })

  let assert True = has_a
  let assert True = has_global
  let assert False = has_b

  // 5. Retrieve session-B datoms (should contain B and global, but not A)
  let assert Ok(res_b) = hermes_state.get_session_datoms(conn, "session-B")
  let has_a_in_b = list.any(res_b, fn(d) { d.entity == "session:session-A" })
  let has_global_in_b = list.any(res_b, fn(d) { d.entity == "rule/global-1" })
  let has_b_in_b = list.any(res_b, fn(d) { d.entity == "session:session-B" })

  let assert False = has_a_in_b
  let assert True = has_global_in_b
  let assert True = has_b_in_b

  // 6. Test retrieval for a clean session (should only contain global rules)
  let assert Ok(res_new) = hermes_state.get_session_datoms(conn, "session-new")
  let has_global_in_new = list.any(res_new, fn(d) { d.entity == "rule/global-1" })
  let has_a_in_new = list.any(res_new, fn(d) { d.entity == "session:session-A" })
  let assert True = has_global_in_new
  let assert False = has_a_in_new

  // 7. Test table deletion (resource cleanup)
  let assert Ok(Nil) = hermes_state.delete_session_datoms(conn, "session-A")
  let assert Ok(res_a_after) = hermes_state.get_session_datoms(conn, "session-A")
  let has_a_after = list.any(res_a_after, fn(d) { d.entity == "session:session-A" })
  let has_global_after = list.any(res_a_after, fn(d) { d.entity == "rule/global-1" })
  let assert False = has_a_after
  let assert True = has_global_after

  // 8. Test validation safety against SQL injection/special characters
  let assert Error(_) = hermes_state.get_session_datoms(conn, "invalid;drop table datoms;")
  let assert Error(_) = hermes_state.save_session_datoms(conn, "invalid;drop table datoms;", [], 0)

  let _ = sqlight.close(conn)
  Nil
}
