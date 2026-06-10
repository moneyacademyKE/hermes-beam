import gleam/erlang/process
import gleam/io
import hermes_state
import sqlight
import state_actor
import subagent_supervisor

pub fn supervisor_start_worker_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = hermes_state.init_schema(conn)
  let assert Ok(actor) = state_actor.start(conn, [])

  let assert Ok(subj) = subagent_supervisor.start_supervisor("test.sock", actor)

  // Ask supervisor to start the worker process
  io.println("Asking supervisor to start worker...")
  process.send(
    subj,
    subagent_supervisor.StartSubagent(
      "worker_1",
      "test prompt",
      "api_key",
      "base_url",
      "[]",
    ),
  )

  // Wait a bit for it to connect and send init
  process.sleep(100)

  io.println("Done")
}

pub fn supervisor_pool_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = hermes_state.init_schema(conn)
  let assert Ok(actor) = state_actor.start(conn, [])

  let assert Ok(subj) = subagent_supervisor.start_supervisor("test.sock", actor)

  // Start 6 workers. Supervisor max is 5.
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w1", "prompt", "api", "base", "[]"),
  )
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w2", "prompt", "api", "base", "[]"),
  )
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w3", "prompt", "api", "base", "[]"),
  )
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w4", "prompt", "api", "base", "[]"),
  )
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w5", "prompt", "api", "base", "[]"),
  )

  // This one should be queued
  process.send(
    subj,
    subagent_supervisor.StartSubagent(
      "w6_queued",
      "prompt",
      "api",
      "base",
      "[]",
    ),
  )

  process.sleep(50)

  // Simulate worker 1 done
  process.send(subj, subagent_supervisor.WorkerDone("w1"))

  // Sleep so w6 is dequeued
  process.sleep(50)
}
