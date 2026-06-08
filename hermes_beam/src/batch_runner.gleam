import gleam/list
import gleam/int
import gleam/erlang/process.{type Subject}
import state_actor.{type StateActor}
import utils

pub type Task(a) {
  Task(subject: Subject(a))
}

pub fn async(fun: fn() -> a) -> Task(a) {
  let subject = process.new_subject()
  process.spawn(fn() {
    let res = fun()
    process.send(subject, res)
  })
  Task(subject)
}

pub fn try_await(task: Task(a), timeout_ms: Int) -> Result(a, Nil) {
  process.receive(task.subject, timeout_ms)
}


@external(erlang, "erlang", "system_time")
fn system_time() -> Int

/// Runs the worker function in parallel across a list of prompts.
/// It dynamically splits the inputs into chunks of size `max_workers`
/// and executes the workers concurrently within each chunk using custom task processes.
pub fn run_batch_parallel(
  prompts: List(String),
  run_worker: fn(String) -> String,
  max_workers: Int,
  actor: StateActor,
) -> List(String) {
  let chunk_size = case max_workers <= 0 {
    True -> 1
    False -> max_workers
  }

  let chunks = list.sized_chunk(prompts, chunk_size)

  list.flat_map(chunks, fn(chunk) {
    let tasks =
      list.map(chunk, fn(prompt) {
        async(fn() { run_worker(prompt) })
      })

    list.map(tasks, fn(t) {
      case try_await(t, 30_000) {
        Ok(res) -> {
          // Send telemetry event using the injected state actor
          let _ = process.send(
            state_actor.get_subject(actor),
            state_actor.InsertTelemetry(
              session_id: "batch_run",
              log_level: "INFO",
              message: "Batch item completed",
              metadata: res,
              timestamp: int.to_float(system_time()) /. 1_000_000_000.0,
            ),
          )
          res
        }
        Error(_) -> {
          let err_res = "error: timeout"
          let _ = process.send(
            state_actor.get_subject(actor),
            state_actor.InsertTelemetry(
              session_id: "batch_run",
              log_level: "ERROR",
              message: "Batch item timeout",
              metadata: err_res,
              timestamp: int.to_float(system_time()) /. 1_000_000_000.0,
            ),
          )
          err_res
        }
      }
    })
  })
}
