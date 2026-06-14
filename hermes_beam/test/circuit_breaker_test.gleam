import circuit_breaker_actor
import gleam/erlang/process

pub fn circuit_breaker_flow_test() {
  // Threshold 3, Cooldown 1 second
  let assert Ok(cb) = circuit_breaker_actor.start(3, 1)
  let model = "test-model"

  // 1. Initial state: Allowed
  let assert True = circuit_breaker_actor.check(cb, model)

  // 2. Failure 1: Still allowed
  circuit_breaker_actor.record_failure(cb, model)
  let assert True = circuit_breaker_actor.check(cb, model)

  // 3. Success resets failures
  circuit_breaker_actor.record_success(cb, model)
  circuit_breaker_actor.record_failure(cb, model)
  circuit_breaker_actor.record_failure(cb, model)
  let assert True = circuit_breaker_actor.check(cb, model)

  // 4. Threshold hit: Failure 3 -> Blocked (Open)
  circuit_breaker_actor.record_failure(cb, model)
  let assert False = circuit_breaker_actor.check(cb, model)

  // 5. Cooldown period: Sleep 1100ms
  process.sleep(1100)

  // 6. Allowed again (transitions to HalfOpen on check)
  let assert True = circuit_breaker_actor.check(cb, model)

  // 7. Success in HalfOpen -> Resets to Closed
  circuit_breaker_actor.record_success(cb, model)
  let assert True = circuit_breaker_actor.check(cb, model)
}
