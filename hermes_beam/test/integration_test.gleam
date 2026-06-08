import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleamdb.{Datom}
import hermes_state
import state_actor
import batch_runner
import telegram_gateway
import sqlight

pub fn state_actor_integration_test() {
  // 1. Open an in-memory SQLite connection
  let assert Ok(conn) = sqlight.open(":memory:")
  
  // 2. Initialize schema (which now includes the datoms table schema migration)
  let assert Ok(Nil) = hermes_state.init_schema(conn)
  
  // 3. Start the StateActor process wrapping the connection
  let assert Ok(actor) = state_actor.start(conn, [])
  
  // 4. Transact some datoms to SQLite via the actor
  let datoms = [
    Datom("alice", "user/role", "engineer"),
    Datom("bob", "user/role", "manager"),
  ]
  let assert Ok(Nil) = state_actor.transact(actor, datoms, 1)
  
  // 5. Load the database snapshot via the actor
  let assert Ok(db) = state_actor.load(actor)
  
  // 6. Query the database to verify persistence works
  let results =
    gleamdb.query(db, [
      #("?user", "user/role", "engineer"),
    ])
    
  let assert 1 = list.length(results)
  let assert Ok(res) = list.first(results)
  let assert Ok("alice") = dict.get(res, "?user")
  
  // 7. Close the actor safely
  let assert Ok(Nil) = state_actor.close(actor)
}

pub fn state_actor_session_integration_test() {
  // 1. Open an in-memory SQLite connection
  let assert Ok(conn) = sqlight.open(":memory:")
  
  // 2. Initialize schema
  let assert Ok(Nil) = hermes_state.init_schema(conn)
  
  // 3. Start the StateActor process wrapping the connection
  let assert Ok(actor) = state_actor.start(conn, [])
  
  // 4. Create a session via the actor
  let assert Ok(Nil) =
    state_actor.create_session(
      actor,
      "session-test",
      "integration-test",
      "mock-model",
      "System prompt here.",
      1_700_000_000.0,
    )
  
  // 5. Update CWD via the actor
  let assert Ok(Nil) =
    state_actor.update_session_cwd(actor, "session-test", "/new/cwd")
  
  // 6. Insert message via the actor
  let assert Ok(Nil) =
    state_actor.insert_message(
      actor,
      "session-test",
      "user",
      "Hello via actor!",
      "{\"role\":\"user\"}",
      1_700_000_100.0,
    )
  
  // 7. End session via the actor
  let assert Ok(Nil) =
    state_actor.end_session(actor, "session-test", "finished", 1_700_000_200.0)
    
  // 8. Close the actor safely
  let assert Ok(Nil) = state_actor.close(actor)
}

pub fn batch_runner_integration_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = hermes_state.init_schema(conn)
  let assert Ok(actor) = state_actor.start(conn, [])

  let prompts = ["prompt_1", "prompt_2", "prompt_3", "prompt_4"]
  
  // Define a simple worker function that appends a suffix
  let run_worker = fn(prompt) {
    prompt <> "_processed"
  }
  
  // Execute prompts concurrently with 2 workers
  let results = batch_runner.run_batch_parallel(prompts, run_worker, 2, actor)
  
  // Assertions
  let assert 4 = list.length(results)
  let assert ["prompt_1_processed", "prompt_2_processed", "prompt_3_processed", "prompt_4_processed"] = results
}

pub fn telegram_parser_integration_test() {
  let mock_json = "
    {
      \"ok\": true,
      \"result\": [
        {
          \"update_id\": 10001,
          \"message\": {
            \"chat\": {
              \"id\": 9999
            },
            \"text\": \"Hello Bot!\"
          }
        },
        {
          \"update_id\": 10002,
          \"message\": {
            \"chat\": {
              \"id\": 9999
            },
            \"text\": \"How are you?\"
          }
        }
      ]
    }
  "
  
  let #(next_offset, messages) = telegram_gateway.parse_telegram_updates(mock_json)
  
  // Offset should be the maximum update ID
  let assert Some(10002) = next_offset
  
  // Message counts
  let assert 2 = list.length(messages)
  let assert Ok(msg1) = list.first(messages)
  let assert 9999 = msg1.chat_id
  let assert "Hello Bot!" = msg1.text
}
