import gleam/option.{Some, None}
import gleam/json
import gleam/dynamic/decode
import usage_pricing.{
  CanonicalUsage,
  resolve_billing_route, normalize_anthropic_model_name,
  normalize_usage, estimate_usage_cost,
  format_duration_compact, format_token_count_compact
}

pub fn resolve_billing_route_test() {
  // 1. OpenAI Codex
  let route = resolve_billing_route("gpt-4", Some("openai-codex"), None)
  let assert "openai-codex" = route.provider
  let assert "subscription_included" = route.billing_mode

  // 2. OpenRouter
  let route = resolve_billing_route("meta-llama/llama-3", Some("openrouter"), None)
  let assert "openrouter" = route.provider
  let assert "official_models_api" = route.billing_mode

  // 3. OpenRouter via URL match
  let route = resolve_billing_route("meta-llama/llama-3", None, Some("https://openrouter.ai/api/v1"))
  let assert "openrouter" = route.provider
  let assert "official_models_api" = route.billing_mode

  // 4. Anthropic
  let route = resolve_billing_route("anthropic/claude-opus-4-8", None, None)
  let assert "anthropic" = route.provider
  let assert "claude-opus-4-8" = route.model
  let assert "official_docs_snapshot" = route.billing_mode

  // 5. Minimax
  let route = resolve_billing_route("minimax-m2.7", Some("minimax"), None)
  let assert "minimax" = route.provider
  let assert "official_docs_snapshot" = route.billing_mode

  // 6. Custom
  let route = resolve_billing_route("my-local-model", Some("local"), Some("http://localhost:8000"))
  let assert "local" = route.provider
  let assert "unknown" = route.billing_mode
}

pub fn normalize_anthropic_model_name_test() {
  let assert "claude-opus-4-7" = normalize_anthropic_model_name("anthropic/claude-opus-4.7")
  let assert "claude-sonnet-4-6" = normalize_anthropic_model_name("claude-sonnet-4.6")
  let assert "claude-3-5-sonnet" = normalize_anthropic_model_name("claude-3.5-sonnet")
}

pub fn normalize_usage_test() {
  // 1. Anthropic style
  let raw_json = "
  {
    \"input_tokens\": 100,
    \"output_tokens\": 50,
    \"cache_read_input_tokens\": 20,
    \"cache_creation_input_tokens\": 10
  }
  "
  let assert Ok(dyn_usage) = json.parse(raw_json, decode.dynamic)
  let usage = normalize_usage(dyn_usage, Some("anthropic"), None)
  let assert 100 = usage.input_tokens
  let assert 50 = usage.output_tokens
  let assert 20 = usage.cache_read_tokens
  let assert 10 = usage.cache_write_tokens

  // 2. Codex style
  let raw_json = "
  {
    \"input_tokens\": 200,
    \"output_tokens\": 80,
    \"input_tokens_details\": {
      \"cached_tokens\": 50,
      \"cache_creation_tokens\": 30
    }
  }
  "
  let assert Ok(dyn_usage) = json.parse(raw_json, decode.dynamic)
  let usage = normalize_usage(dyn_usage, None, Some("codex_responses"))
  // input = total (200) - cached (50) - write (30) = 120
  let assert 120 = usage.input_tokens
  let assert 80 = usage.output_tokens
  let assert 50 = usage.cache_read_tokens
  let assert 30 = usage.cache_write_tokens

  // 3. OpenAI style
  let raw_json = "
  {
    \"prompt_tokens\": 300,
    \"completion_tokens\": 150,
    \"prompt_tokens_details\": {
      \"cached_tokens\": 100,
      \"cache_write_tokens\": 50
    },
    \"output_tokens_details\": {
      \"reasoning_tokens\": 40
    }
  }
  "
  let assert Ok(dyn_usage) = json.parse(raw_json, decode.dynamic)
  let usage = normalize_usage(dyn_usage, Some("openai"), None)
  // input = total (300) - cached (100) - write (50) = 150
  let assert 150 = usage.input_tokens
  let assert 150 = usage.output_tokens
  let assert 100 = usage.cache_read_tokens
  let assert 50 = usage.cache_write_tokens
  let assert 40 = usage.reasoning_tokens
}

pub fn estimate_usage_cost_test() {
  // 1. Claude Opus 4.8 snapshot
  // input_cost = $5.00/M, output_cost = $25.00/M, cache_read = $0.50/M, cache_write = $6.25/M
  let usage = CanonicalUsage(
    input_tokens: 1_000_000,
    output_tokens: 1_000_000,
    cache_read_tokens: 1_000_000,
    cache_write_tokens: 1_000_000,
    reasoning_tokens: 0,
    request_count: 1,
  )
  let cost = estimate_usage_cost("claude-opus-4-8", usage, Some("anthropic"), None)
  // expected cost = 5.00 + 25.00 + 0.50 + 6.25 = 36.75
  let assert Some(amount) = cost.amount_usd
  let assert True = amount >. 36.74 && amount <. 36.76
  let assert "estimated" = cost.status

  // 2. Subscription included
  let cost = estimate_usage_cost("gpt-4", usage, Some("openai-codex"), None)
  let assert Some(0.0) = cost.amount_usd
  let assert "included" = cost.status

  // 3. Unknown model
  let cost = estimate_usage_cost("some-future-model", usage, Some("openai"), None)
  let assert None = cost.amount_usd
  let assert "unknown" = cost.status
}

pub fn format_duration_compact_test() {
  let assert "45s" = format_duration_compact(45.2)
  let assert "2m" = format_duration_compact(120.0)
  let assert "1h" = format_duration_compact(3600.0)
  let assert "1h 1m" = format_duration_compact(3660.0)
  let assert "1.0d" = format_duration_compact(90000.0)
}

pub fn format_token_count_compact_test() {
  let assert "500" = format_token_count_compact(500)
  let assert "1.5K" = format_token_count_compact(1500)
  let assert "1.5M" = format_token_count_compact(1_500_000)
  let assert "1.5B" = format_token_count_compact(1_500_000_000)
  let assert "-5K" = format_token_count_compact(-5000)
}
