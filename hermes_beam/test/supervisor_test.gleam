import constants
import gleam/erlang/process
import gleam/io
import hermes_exec
import hermes_state
import sqlight
import state_actor
import subagent_supervisor

pub fn supervisor_start_worker_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = hermes_state.init_schema(conn)
  let assert Ok(actor) = state_actor.start(conn, [])

  let socket_path = constants.path_join(hermes_exec.get_temp_dir(), "test.sock")
  let assert Ok(subj) = subagent_supervisor.start_supervisor(socket_path, actor)

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
      "gpt-4o-mini",
    ),
  )

  // Wait a bit for it to connect and send init
  process.sleep(100)

  io.println("Done")

  let assert Ok(pid) = process.subject_owner(subj)
  let _monitor = process.monitor(pid)
  process.send(subj, subagent_supervisor.Shutdown)
  let selector = process.new_selector() |> process.select_monitors(fn(d) { d })
  let assert Ok(_) = process.selector_receive(selector, 1000)
}

pub fn supervisor_pool_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = hermes_state.init_schema(conn)
  let assert Ok(actor) = state_actor.start(conn, [])

  let socket_path = constants.path_join(hermes_exec.get_temp_dir(), "test_pool.sock")
  let assert Ok(subj) = subagent_supervisor.start_supervisor(socket_path, actor)

  // Start 6 workers. Supervisor max is 5.
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w1", "prompt", "api", "base", "[]", "gpt-4o-mini"),
  )
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w2", "prompt", "api", "base", "[]", "gpt-4o-mini"),
  )
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w3", "prompt", "api", "base", "[]", "gpt-4o-mini"),
  )
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w4", "prompt", "api", "base", "[]", "gpt-4o-mini"),
  )
  process.send(
    subj,
    subagent_supervisor.StartSubagent("w5", "prompt", "api", "base", "[]", "gpt-4o-mini"),
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
      "gpt-4o-mini",
    ),
  )

  process.sleep(50)

  // Simulate worker 1 done
  process.send(subj, subagent_supervisor.WorkerDone("w1"))

  // Sleep so w6 is dequeued
  process.sleep(50)

  let assert Ok(pid) = process.subject_owner(subj)
  let _monitor = process.monitor(pid)
  process.send(subj, subagent_supervisor.Shutdown)
  let selector = process.new_selector() |> process.select_monitors(fn(d) { d })
  let assert Ok(_) = process.selector_receive(selector, 1000)
}

pub fn supervisor_escape_json_string_test() {
  let input = "Hello\nWorld \"with quotes\" \\and backslash\\\r\ttab"
  let expected = "Hello\\nWorld \\\"with quotes\\\" \\\\and backslash\\\\\\r\\ttab"
  let assert True = subagent_supervisor.escape_json_string(input) == expected
}
