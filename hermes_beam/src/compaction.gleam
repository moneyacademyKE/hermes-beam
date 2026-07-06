import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type CompactionTier {
  NoCompaction
  SoftTrigger(threshold_pct: Int)
  HardTrigger(threshold_pct: Int)
}

pub type CompactionConfig {
  CompactionConfig(
    context_window: Int,
    soft_pct: Int,
    hard_pct: Int,
    protect_first_n: Int,
    tail_budget_chars: Int,
    enabled: Bool,
  )
}

pub fn default_config() -> CompactionConfig {
  CompactionConfig(
    context_window: 200_000,
    soft_pct: 65,
    hard_pct: 90,
    protect_first_n: 1,
    tail_budget_chars: 10_000,
    enabled: True,
  )
}

pub fn config_from_env(
  get_env: fn(String) -> Option(String),
) -> CompactionConfig {
  let base = default_config()
  let window = case get_env("HERMES_CONTEXT_WINDOW") {
    Some(val) -> case int.parse(val) {
      Ok(n) -> n
      Error(_) -> base.context_window
    }
    None -> base.context_window
  }
  let soft = case get_env("HERMES_COMPACTION_SOFT_PCT") {
    Some(val) -> case int.parse(val) {
      Ok(n) -> n
      Error(_) -> base.soft_pct
    }
    None -> base.soft_pct
  }
  let hard = case get_env("HERMES_COMPACTION_HARD_PCT") {
    Some(val) -> case int.parse(val) {
      Ok(n) -> n
      Error(_) -> base.hard_pct
    }
    None -> base.hard_pct
  }
  CompactionConfig(
    context_window: window,
    soft_pct: soft,
    hard_pct: hard,
    protect_first_n: base.protect_first_n,
    tail_budget_chars: base.tail_budget_chars,
    enabled: True,
  )
}

pub fn estimate_tokens(text: String) -> Int {
  let chars = string.length(text)
  { chars * 100 } / 400
}

pub fn estimate_messages_tokens(messages: List(String)) -> Int {
  list.fold(messages, 0, fn(acc, msg) {
    acc + estimate_tokens(msg)
  })
}

pub fn check_threshold(
  config: CompactionConfig,
  used_tokens: Int,
) -> CompactionTier {
  case config.enabled {
    False -> NoCompaction
    True -> {
      let pct = { used_tokens * 100 } / config.context_window
      case pct >= config.hard_pct {
        True -> HardTrigger(config.hard_pct)
        False ->
          case pct >= config.soft_pct {
            True -> SoftTrigger(config.soft_pct)
            False -> NoCompaction
          }
      }
    }
  }
}

pub fn context_usage_pct(
  config: CompactionConfig,
  used_tokens: Int,
) -> Int {
  case config.context_window {
    0 -> 0
    window -> { used_tokens * 100 } / window
  }
}

pub fn should_block_request(tier: CompactionTier) -> Bool {
  case tier {
    HardTrigger(_) -> True
    _ -> False
  }
}

pub fn is_background_trigger(tier: CompactionTier) -> Bool {
  case tier {
    SoftTrigger(_) -> True
    _ -> False
  }
}

pub fn format_status(
  config: CompactionConfig,
  used_tokens: Int,
) -> String {
  let pct = context_usage_pct(config, used_tokens)
  let remaining = config.context_window - used_tokens
  "ctx: "
  <> int.to_string(used_tokens)
  <> "/"
  <> int.to_string(config.context_window)
  <> " ("
  <> int.to_string(pct)
  <> "%) — "
  <> int.to_string(remaining)
  <> " tokens remaining"
}

pub fn compaction_plan(
  config: CompactionConfig,
  messages: List(String),
) -> #(List(String), List(String), List(String)) {
  let count = list.length(messages)
  let first_n = case count <= config.protect_first_n {
    True -> messages
    False -> list.take(messages, config.protect_first_n)
  }
  let rest = case count <= config.protect_first_n {
    True -> []
    False -> list.drop(messages, config.protect_first_n)
  }
  let tail_chars = config.tail_budget_chars
  let #(middle, tail) = split_by_char_budget(rest, tail_chars)
  #(first_n, middle, tail)
}

fn split_by_char_budget(
  messages: List(String),
  budget: Int,
) -> #(List(String), List(String)) {
  let reversed = list.reverse(messages)
  split_from_tail(reversed, [], budget)
}

fn split_from_tail(
  remaining: List(String),
  tail: List(String),
  budget: Int,
) -> #(List(String), List(String)) {
  case remaining {
    [] -> #([], tail)
    [msg, ..rest] -> {
      let msg_chars = string.length(msg)
      case budget >= msg_chars {
        True ->
          split_from_tail(rest, [msg, ..tail], budget - msg_chars)
        False -> #(list.reverse(remaining), tail)
      }
    }
  }
}
