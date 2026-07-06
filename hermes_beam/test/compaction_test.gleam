import compaction
import gleam/option

pub fn compaction_default_config_test() {
  let config = compaction.default_config()
  let assert 200_000 = compaction_test_helper_window(config)
  let assert 65 = compaction_test_helper_soft(config)
  let assert 90 = compaction_test_helper_hard(config)
}

pub fn compaction_no_trigger_test() {
  let config = compaction.default_config()
  let tier = compaction.check_threshold(config, 10_000)
  let assert compaction.NoCompaction = tier
}

pub fn compaction_soft_trigger_test() {
  let config = compaction.CompactionConfig(
    context_window: 100_000,
    soft_pct: 65,
    hard_pct: 90,
    protect_first_n: 1,
    tail_budget_chars: 10_000,
    enabled: True,
  )
  let tier = compaction.check_threshold(config, 70_000)
  let assert compaction.SoftTrigger(65) = tier
}

pub fn compaction_hard_trigger_test() {
  let config = compaction.CompactionConfig(
    context_window: 100_000,
    soft_pct: 65,
    hard_pct: 90,
    protect_first_n: 1,
    tail_budget_chars: 10_000,
    enabled: True,
  )
  let tier = compaction.check_threshold(config, 95_000)
  let assert compaction.HardTrigger(90) = tier
}

pub fn compaction_disabled_test() {
  let config = compaction.CompactionConfig(
    context_window: 100_000,
    soft_pct: 65,
    hard_pct: 90,
    protect_first_n: 1,
    tail_budget_chars: 10_000,
    enabled: False,
  )
  let tier = compaction.check_threshold(config, 99_000)
  let assert compaction.NoCompaction = tier
}

pub fn compaction_context_usage_pct_test() {
  let config = compaction.default_config()
  let pct = compaction.context_usage_pct(config, 50_000)
  let assert 25 = pct
}

pub fn compaction_should_block_request_test() {
  let assert True = compaction.should_block_request(compaction.HardTrigger(90))
  let assert False = compaction.should_block_request(compaction.SoftTrigger(65))
  let assert False = compaction.should_block_request(compaction.NoCompaction)
}

pub fn compaction_is_background_trigger_test() {
  let assert True = compaction.is_background_trigger(compaction.SoftTrigger(65))
  let assert False = compaction.is_background_trigger(compaction.HardTrigger(90))
  let assert False = compaction.is_background_trigger(compaction.NoCompaction)
}

pub fn compaction_format_status_test() {
  let config = compaction.default_config()
  let status = compaction.format_status(config, 50_000)
  let assert True = string_contains(status, "ctx:")
  let assert True = string_contains(status, "50000/200000")
  let assert True = string_contains(status, "25%")
}

pub fn compaction_config_from_env_test() {
  let config = compaction.config_from_env(fn(_) { option.None })
  let assert 200_000 = compaction_test_helper_window(config)
}

fn compaction_test_helper_window(config: compaction.CompactionConfig) -> Int {
  let compaction.CompactionConfig(context_window: w, ..) = config
  w
}

fn compaction_test_helper_soft(config: compaction.CompactionConfig) -> Int {
  let compaction.CompactionConfig(soft_pct: s, ..) = config
  s
}

fn compaction_test_helper_hard(config: compaction.CompactionConfig) -> Int {
  let compaction.CompactionConfig(hard_pct: h, ..) = config
  h
}

fn string_contains(haystack: String, needle: String) -> Bool {
  case string_find(haystack, needle) {
    Ok(_) -> True
    Error(_) -> False
  }
}

@external(erlang, "string", "find")
fn string_find(haystack: String, needle: String) -> Result(String, Nil)
