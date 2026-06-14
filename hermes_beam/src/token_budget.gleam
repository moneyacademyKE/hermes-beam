import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result

pub type Message {
  CheckBudget(reply_to: Subject(Bool))
  RecordTokens(tokens: Int)
  GetUsed(reply_to: Subject(Int))
  GetRemaining(reply_to: Subject(Int))
}

pub type BudgetState {
  BudgetState(max_total: Int, used: Int)
}

pub opaque type TokenBudget {
  TokenBudget(subject: Subject(Message))
}

/// Starts a new thread-safe process managing the token budget state.
pub fn start(max_total: Int) -> Result(TokenBudget, actor.StartError) {
  let initial_state = BudgetState(max_total: max_total, used: 0)
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { TokenBudget(started.data) })
}

/// The internal actor loop handling state transitions.
fn handle_message(
  state: BudgetState,
  message: Message,
) -> actor.Next(BudgetState, Message) {
  case message {
    CheckBudget(reply_to) -> {
      let allowed = state.used < state.max_total
      process.send(reply_to, allowed)
      actor.continue(state)
    }
    RecordTokens(tokens) -> {
      let next_used = state.used + tokens
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

/// Check if the token budget has not been exceeded.
pub fn check(budget: TokenBudget) -> Bool {
  actor.call(budget.subject, 1000, CheckBudget)
}

/// Record additional tokens consumed.
pub fn record(budget: TokenBudget, tokens: Int) -> Nil {
  actor.send(budget.subject, RecordTokens(tokens))
}

/// Returns the number of tokens used so far.
pub fn used(budget: TokenBudget) -> Int {
  actor.call(budget.subject, 1000, GetUsed)
}

/// Returns the remaining tokens in the budget.
pub fn remaining(budget: TokenBudget) -> Int {
  actor.call(budget.subject, 1000, GetRemaining)
}
