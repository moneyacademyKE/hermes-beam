import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result

// ─── Types ────────────────────────────────────────────────────────────────────

pub type CircuitState {
  Closed
  Open(tripped_at: Int)
  HalfOpen
}

pub type ModelStatus {
  ModelStatus(
    state: CircuitState,
    consecutive_failures: Int,
  )
}

pub type Message {
  CheckCircuit(model: String, reply_to: Subject(Bool))
  RecordSuccess(model: String)
  RecordFailure(model: String)
}

pub type BreakerState {
  BreakerState(
    statuses: Dict(String, ModelStatus),
    threshold: Int,
    cooldown_seconds: Int,
  )
}

pub opaque type CircuitBreaker {
  CircuitBreaker(subject: Subject(Message))
}

pub fn from_subject(subject: Subject(Message)) -> CircuitBreaker {
  CircuitBreaker(subject)
}

// ─── FFI Helpers ──────────────────────────────────────────────────────────────

@external(erlang, "erlang", "system_time")
fn ffi_system_time(unit: Dynamic) -> Int

pub fn system_time_seconds() -> Int {
  ffi_system_time(atom.to_dynamic(atom.create("second")))
}

// ─── Constructor ──────────────────────────────────────────────────────────────

/// Starts a new supervised circuit breaker actor process.
pub fn start(
  threshold: Int,
  cooldown_seconds: Int,
) -> Result(CircuitBreaker, actor.StartError) {
  let initial_state =
    BreakerState(
      statuses: dict.new(),
      threshold: threshold,
      cooldown_seconds: cooldown_seconds,
    )
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { CircuitBreaker(started.data) })
}

pub fn start_supervised(
  name: process.Name(Message),
  threshold: Int,
  cooldown_seconds: Int,
) -> Result(actor.Started(CircuitBreaker), actor.StartError) {
  let initial_state =
    BreakerState(
      statuses: dict.new(),
      threshold: threshold,
      cooldown_seconds: cooldown_seconds,
    )
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
  |> result.map(fn(started) {
    actor.Started(pid: started.pid, data: CircuitBreaker(started.data))
  })
}

// ─── internal message handler ───────────────────────────────────────────────

fn handle_message(
  state: BreakerState,
  message: Message,
) -> actor.Next(BreakerState, Message) {
  let current_time = system_time_seconds()

  case message {
    CheckCircuit(model, reply_to) -> {
      let status =
        dict.get(state.statuses, model)
        |> result.unwrap(ModelStatus(Closed, 0))

      case status.state {
        Closed | HalfOpen -> {
          process.send(reply_to, True)
          actor.continue(state)
        }
        Open(tripped_at) -> {
          let elapsed = current_time - tripped_at
          case elapsed >= state.cooldown_seconds {
            True -> {
              // Cooldown finished — transition to HalfOpen and allow request to pass through
              let next_status = ModelStatus(..status, state: HalfOpen)
              let next_statuses = dict.insert(state.statuses, model, next_status)
              process.send(reply_to, True)
              actor.continue(BreakerState(..state, statuses: next_statuses))
            }
            False -> {
              // Cooldown active — block the request
              process.send(reply_to, False)
              actor.continue(state)
            }
          }
        }
      }
    }

    RecordSuccess(model) -> {
      let next_status = ModelStatus(state: Closed, consecutive_failures: 0)
      let next_statuses = dict.insert(state.statuses, model, next_status)
      actor.continue(BreakerState(..state, statuses: next_statuses))
    }

    RecordFailure(model) -> {
      let status =
        dict.get(state.statuses, model)
        |> result.unwrap(ModelStatus(Closed, 0))

      let next_failures = status.consecutive_failures + 1
      let should_trip = next_failures >= state.threshold

      let next_status = case should_trip {
        True -> ModelStatus(state: Open(current_time), consecutive_failures: next_failures)
        False -> ModelStatus(..status, consecutive_failures: next_failures)
      }
      let next_statuses = dict.insert(state.statuses, model, next_status)
      actor.continue(BreakerState(..state, statuses: next_statuses))
    }
  }
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Check if the model is currently allowed to process requests.
/// Returns True if the circuit is Closed or HalfOpen (allowed), False if Open (cooldown).
pub fn check(breaker: CircuitBreaker, model: String) -> Bool {
  actor.call(breaker.subject, 1000, CheckCircuit(model, _))
}

/// Record a successful call. Resets failure counters.
pub fn record_success(breaker: CircuitBreaker, model: String) -> Nil {
  actor.send(breaker.subject, RecordSuccess(model))
}

/// Record a failed call. Increments failure counter and trips circuit if threshold hit.
pub fn record_failure(breaker: CircuitBreaker, model: String) -> Nil {
  actor.send(breaker.subject, RecordFailure(model))
}
