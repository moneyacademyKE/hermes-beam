import datom
import dialectic
import gleam/list
import gleam/string
import hermes_state
import memory_plugin
import sqlight
import state_actor

pub fn gleamdb_memory_retrieval_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(Nil) = sqlight.exec(hermes_state.schema_sql, conn)
  let assert Ok(sa) = state_actor.start(conn, [])

  let plugin = memory_plugin.gleamdb_memory_adapter(sa)

  // Save preference
  let assert Ok(Nil) = plugin.save_context("session-1", "Emacs")

  // Retrieve preference
  let assert Ok(ctx) = plugin.retrieve_context("session-1")
  let assert True = string.contains(ctx, "profile/context: Emacs")
}

pub fn gleamdb_dialectic_contradiction_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(Nil) = sqlight.exec(hermes_state.schema_sql, conn)
  let assert Ok(sa) = state_actor.start(conn, [])

  // Transact contradictory facts
  let datoms = [
    datom.Datom("user:default", "profile/editor", "VS Code"),
    datom.Datom("user:default", "profile/editor", "Emacs"),
  ]

  let assert Ok(Nil) = state_actor.transact(sa, "session-1", datoms, 0)

  // Detect contradictions
  let assert Ok(contradictions) = dialectic.detect_contradictions(sa)

  // We expect exactly 1 contradiction (deduplicated)
  let assert 1 = list.length(contradictions)
  let assert Ok(c) = list.first(contradictions)
  let assert "profile/editor" = c.attribute
  let assert True =
    { c.value1 == "VS Code" && c.value2 == "Emacs" }
    || { c.value1 == "Emacs" && c.value2 == "VS Code" }
}
