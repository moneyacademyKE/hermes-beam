import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result

pub type Message {
  Consume(reply_to: Subject(Bool))
  Refund
  GetUsed(reply_to: Subject(Int))
  GetRemaining(reply_to: Subject(Int))
}

pub type BudgetState {
  BudgetState(max_total: Int, used: Int)
}

pub opaque type IterationBudget {
  IterationBudget(subject: Subject(Message))
}

/// Starts a new thread-safe process managing the iteration budget state.
pub fn start(max_total: Int) -> Result(IterationBudget, actor.StartError) {
  let initial_state = BudgetState(max_total: max_total, used: 0)
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { IterationBudget(started.data) })
}

/// The internal actor loop handling state transitions.
fn handle_message(
  state: BudgetState,
  message: Message,
) -> actor.Next(BudgetState, Message) {
  case message {
    Consume(reply_to) -> {
      let allowed = state.used < state.max_total
      let next_used = case allowed {
        True -> state.used + 1
        False -> state.used
      }
      process.send(reply_to, allowed)
      actor.continue(BudgetState(..state, used: next_used))
    }
    Refund -> {
      let next_used = case state.used > 0 {
        True -> state.used - 1
        False -> 0
      }
      actor.continue(BudgetState(..state, used: next_used))
    }
    GetUsed(reply_to) -> {
      process.send(reply_to, state.used)
      actor.continue(state)
    }
    GetRemaining(reply_to) -> {
      let remaining = state.max_total - state.used
      let remaining = case remaining < 0 {
        True -> 0
        False -> remaining
      }
      process.send(reply_to, remaining)
      actor.continue(state)
    }
  }
}

/// Try to consume one iteration. Returns True if allowed, False otherwise.
pub fn consume(budget: IterationBudget) -> Bool {
  actor.call(budget.subject, 1000, Consume)
}

/// Refund one iteration (e.g. for execute_code turns) so they don't eat into the budget.
pub fn refund(budget: IterationBudget) -> Nil {
  actor.send(budget.subject, Refund)
}

/// Returns the number of iterations used so far.
pub fn used(budget: IterationBudget) -> Int {
  actor.call(budget.subject, 1000, GetUsed)
}

/// Returns the remaining iterations.
pub fn remaining(budget: IterationBudget) -> Int {
  actor.call(budget.subject, 1000, GetRemaining)
}
