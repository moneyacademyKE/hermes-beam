import token_budget

pub fn token_budget_flow_test() {
  // Start with budget of 1000 tokens
  let assert Ok(tb) = token_budget.start(1000)

  // Initial check: budget should be allowed, used 0, remaining 1000
  let assert True = token_budget.check(tb)
  let assert 0 = token_budget.used(tb)
  let assert 1000 = token_budget.remaining(tb)

  // Record some tokens (500)
  token_budget.record(tb, 500)
  let assert True = token_budget.check(tb)
  let assert 500 = token_budget.used(tb)
  let assert 500 = token_budget.remaining(tb)

  // Record more tokens to exceed budget (600 more -> total 1100)
  token_budget.record(tb, 600)
  let assert False = token_budget.check(tb)
  let assert 1100 = token_budget.used(tb)
  let assert 0 = token_budget.remaining(tb)
}
