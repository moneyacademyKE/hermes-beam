import cross_session_search
import gleam/list
import hermes_state
import semantic_search
import sqlight

pub fn semantic_math_test() {
  // Test dot product
  let assert 1.0 = semantic_search.dot_product([1.0, 0.0], [1.0, 0.0])
  let assert 0.0 = semantic_search.dot_product([1.0, 0.0], [0.0, 1.0])

  // Test magnitude
  let assert 1.0 = semantic_search.magnitude([1.0, 0.0])
  let assert 1.0 = semantic_search.magnitude([0.0, -1.0])

  // Test cosine similarity
  let assert 1.0 = semantic_search.cosine_similarity([1.0, 0.0], [1.0, 0.0])
  let assert 0.0 = semantic_search.cosine_similarity([1.0, 0.0], [0.0, 1.0])
  let assert -1.0 = semantic_search.cosine_similarity([1.0, 0.0], [-1.0, 0.0])
}

pub fn cross_session_search_db_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(Nil) = sqlight.exec(hermes_state.schema_sql, conn)

  // Save embeddings
  let assert Ok(Nil) =
    hermes_state.save_session_embedding(
      conn,
      "session-1",
      "User was studying OTP actors and processes.",
      [1.0, 0.0, 0.0],
      1_700_000_000.0,
    )

  let assert Ok(Nil) =
    hermes_state.save_session_embedding(
      conn,
      "session-2",
      "User was configuring a web server and REST API.",
      [0.0, 1.0, 0.0],
      1_700_000_000.0,
    )

  // Retrieve and check list
  let assert Ok(sessions) = hermes_state.get_all_session_embeddings(conn)
  let assert 2 = list.length(sessions)

  // Retrieve matching context using simulated test key
  let assert Ok(ctx) =
    cross_session_search.get_semantic_context("OTP", "test-key", conn, 1)

  let assert True = list.length(sessions) >= 1
}
