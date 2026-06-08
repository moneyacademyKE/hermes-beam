import subagent_supervisor
import gleam/erlang/process
import gleam/io

pub fn supervisor_test() {
  let socket_path = "/tmp/hermes_agent_supervisor_test.sock"
  let datom_subj = process.new_subject()
  let assert Ok(subj) = subagent_supervisor.start_supervisor(socket_path, datom_subj)
  
  // Ask supervisor to start the worker process
  io.println("Asking supervisor to start worker...")
  process.send(subj, subagent_supervisor.StartSubagent("worker_1", "task"))
  
  // Wait a bit for it to connect and send init
  process.sleep(2000)
  
  io.println("Done")
}
