import gleam/list
import gleam/erlang/process.{type Subject}

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

/// Runs the worker function in parallel across a list of prompts.
/// It dynamically splits the inputs into chunks of size `max_workers`
/// and executes the workers concurrently within each chunk using custom task processes.
pub fn run_batch_parallel(
  prompts: List(String),
  run_worker: fn(String) -> String,
  max_workers: Int,
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
        Ok(res) -> res
        Error(_) -> "error: timeout"
      }
    })
  })
}
