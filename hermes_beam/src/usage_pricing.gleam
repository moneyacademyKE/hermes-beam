import gleam/option.{type Option, Some, None}
import gleam/string
import gleam/int
import gleam/float
import gleam/list
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import utils

pub type CanonicalUsage {
  CanonicalUsage(
    input_tokens: Int,
    output_tokens: Int,
    cache_read_tokens: Int,
    cache_write_tokens: Int,
    reasoning_tokens: Int,
    request_count: Int,
  )
}

pub type BillingRoute {
  BillingRoute(
    provider: String,
    model: String,
    base_url: String,
    billing_mode: String,
  )
}

pub type PricingEntry {
  PricingEntry(
    input_cost_per_million: Option(Float),
    output_cost_per_million: Option(Float),
    cache_read_cost_per_million: Option(Float),
    cache_write_cost_per_million: Option(Float),
    request_cost: Option(Float),
    source: String,
    source_url: Option(String),
    pricing_version: Option(String),
    fetched_at: Option(Int),
  )
}

pub type CostResult {
  CostResult(
    amount_usd: Option(Float),
    status: String,
    source: String,
    label: String,
    fetched_at: Option(Int),
    pricing_version: Option(String),
    notes: List(String),
  )
}

fn get_int_field(data: Dynamic, field_name: String) -> Int {
  let decoder = decode.field(field_name, decode.int, decode.success)
  case decode.run(data, decoder) {
    Ok(val) -> val
    Error(_) -> 0
  }
}

fn get_field_dynamic(data: Dynamic, field_name: String) -> Dynamic {
  let decoder = decode.field(field_name, decode.dynamic, decode.success)
  case decode.run(data, decoder) {
    Ok(val) -> val
    Error(_) -> dynamic.nil()
  }
}

fn get_output_reasoning_tokens(response_usage: Dynamic) -> Int {
  let output_details = get_field_dynamic(response_usage, "output_tokens_details")
  get_int_field(output_details, "reasoning_tokens")
}

pub fn prompt_tokens(usage: CanonicalUsage) -> Int {
  usage.input_tokens + usage.cache_read_tokens + usage.cache_write_tokens
}

pub fn total_tokens(usage: CanonicalUsage) -> Int {
  prompt_tokens(usage) + usage.output_tokens
}

pub fn resolve_billing_route(
  model_name: String,
  provider provider: Option(String),
  base_url base_url: Option(String),
) -> BillingRoute {
  let provider_raw = option.unwrap(provider, "")
  let provider_name = string.lowercase(string.trim(provider_raw))
  let base_raw = option.unwrap(base_url, "")
  let base = string.lowercase(string.trim(base_raw))
  let model = string.trim(model_name)
  
  let #(provider_name, model) = case provider_name == "" && string.contains(model, "/") {
    True -> {
      case string.split_once(model, "/") {
        Ok(#(inferred, bare)) -> {
          case inferred == "anthropic" || inferred == "openai" || inferred == "google" {
            True -> #(inferred, bare)
            False -> #(provider_name, model)
          }
        }
        Error(_) -> #(provider_name, model)
      }
    }
    False -> #(provider_name, model)
  }

  let last_segment = fn(m: String) {
    case string.split(m, "/") {
      [] -> ""
      parts -> {
        let assert Ok(last) = list.last(parts)
        last
      }
    }
  }

  let is_localhost = string.contains(base, "localhost")

  case provider_name {
    "openai-codex" -> {
      BillingRoute(
        provider: "openai-codex",
        model: model,
        base_url: base_raw,
        billing_mode: "subscription_included",
      )
    }
    "openrouter" -> {
      BillingRoute(
        provider: "openrouter",
        model: model,
        base_url: base_raw,
        billing_mode: "official_models_api",
      )
    }
    _ if provider_name == "anthropic" -> {
      BillingRoute(
        provider: "anthropic",
        model: last_segment(model),
        base_url: base_raw,
        billing_mode: "official_docs_snapshot",
      )
    }
    _ if provider_name == "openai" -> {
      BillingRoute(
        provider: "openai",
        model: last_segment(model),
        base_url: base_raw,
        billing_mode: "official_docs_snapshot",
      )
    }
    _ if provider_name == "minimax" || provider_name == "minimax-cn" -> {
      BillingRoute(
        provider: provider_name,
        model: last_segment(model),
        base_url: base_raw,
        billing_mode: "official_docs_snapshot",
      )
    }
    _ if provider_name == "custom" || provider_name == "local" || is_localhost -> {
      let prov = case provider_name {
        "" -> "custom"
        p -> p
      }
      BillingRoute(
        provider: prov,
        model: model,
        base_url: base_raw,
        billing_mode: "unknown",
      )
    }
    _ -> {
      case utils.base_url_host_matches(base_raw, "openrouter.ai") {
        True -> {
          BillingRoute(
            provider: "openrouter",
            model: model,
            base_url: base_raw,
            billing_mode: "official_models_api",
          )
        }
        False -> {
          let prov = case provider_name {
            "" -> "unknown"
            p -> p
          }
          BillingRoute(
            provider: prov,
            model: last_segment(model),
            base_url: base_raw,
            billing_mode: "unknown",
          )
        }
      }
    }
  }
}

pub fn normalize_anthropic_model_name(model: String) -> String {
  let name = string.lowercase(string.trim(model))
  let name = case string.starts_with(name, "anthropic/") {
    True -> string.drop_start(name, 10)
    False -> name
  }
  name
  |> string.replace("4.8", "4-8")
  |> string.replace("4.7", "4-7")
  |> string.replace("4.6", "4-6")
  |> string.replace("4.5", "4-5")
  |> string.replace("3.5", "3-5")
}

pub fn lookup_official_docs_pricing(provider: String, model: String) -> Option(PricingEntry) {
  let pair = #(provider, model)
  case pair {
    #("anthropic", "claude-opus-4-8") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(5.00),
        output_cost_per_million: Some(25.00),
        cache_read_cost_per_million: Some(0.50),
        cache_write_cost_per_million: Some(6.25),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-opus-4-8-fast") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(10.00),
        output_cost_per_million: Some(50.00),
        cache_read_cost_per_million: Some(1.00),
        cache_write_cost_per_million: Some(12.50),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://openrouter.ai/anthropic/claude-opus-4-8-fast"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-opus-4-7")
    | #("anthropic", "claude-opus-4-7-20250507")
    | #("anthropic", "claude-opus-4-6")
    | #("anthropic", "claude-opus-4-6-20250414")
    | #("anthropic", "claude-opus-4-5") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(5.00),
        output_cost_per_million: Some(25.00),
        cache_read_cost_per_million: Some(0.50),
        cache_write_cost_per_million: Some(6.25),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-sonnet-4-6")
    | #("anthropic", "claude-sonnet-4-6-20250414")
    | #("anthropic", "claude-sonnet-4-5") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(3.00),
        output_cost_per_million: Some(15.00),
        cache_read_cost_per_million: Some(0.30),
        cache_write_cost_per_million: Some(3.75),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-haiku-4-5") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(1.00),
        output_cost_per_million: Some(5.00),
        cache_read_cost_per_million: Some(0.10),
        cache_write_cost_per_million: Some(1.25),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-opus-4-20250514") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(15.00),
        output_cost_per_million: Some(75.00),
        cache_read_cost_per_million: Some(1.50),
        cache_write_cost_per_million: Some(18.75),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-sonnet-4-20250514") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(3.00),
        output_cost_per_million: Some(15.00),
        cache_read_cost_per_million: Some(0.30),
        cache_write_cost_per_million: Some(3.75),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("openai", "gpt-4o") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(2.50),
        output_cost_per_million: Some(10.00),
        cache_read_cost_per_million: Some(1.25),
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://openai.com/api/pricing/"),
        pricing_version: Some("openai-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("openai", "gpt-4o-mini") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.15),
        output_cost_per_million: Some(0.60),
        cache_read_cost_per_million: Some(0.075),
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://openai.com/api/pricing/"),
        pricing_version: Some("openai-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("openai", "gpt-4.1") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(2.00),
        output_cost_per_million: Some(8.00),
        cache_read_cost_per_million: Some(0.50),
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://openai.com/api/pricing/"),
        pricing_version: Some("openai-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("openai", "gpt-4.1-mini") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.40),
        output_cost_per_million: Some(1.60),
        cache_read_cost_per_million: Some(0.10),
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://openai.com/api/pricing/"),
        pricing_version: Some("openai-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("openai", "gpt-4.1-nano") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.10),
        output_cost_per_million: Some(0.40),
        cache_read_cost_per_million: Some(0.025),
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://openai.com/api/pricing/"),
        pricing_version: Some("openai-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("openai", "o3") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(10.00),
        output_cost_per_million: Some(40.00),
        cache_read_cost_per_million: Some(2.50),
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://openai.com/api/pricing/"),
        pricing_version: Some("openai-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("openai", "o3-mini") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(1.10),
        output_cost_per_million: Some(4.40),
        cache_read_cost_per_million: Some(0.55),
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://openai.com/api/pricing/"),
        pricing_version: Some("openai-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-3-5-sonnet-20241022") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(3.00),
        output_cost_per_million: Some(15.00),
        cache_read_cost_per_million: Some(0.30),
        cache_write_cost_per_million: Some(3.75),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-3-5-haiku-20241022") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.80),
        output_cost_per_million: Some(4.00),
        cache_read_cost_per_million: Some(0.08),
        cache_write_cost_per_million: Some(1.00),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-3-opus-20240229") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(15.00),
        output_cost_per_million: Some(75.00),
        cache_read_cost_per_million: Some(1.50),
        cache_write_cost_per_million: Some(18.75),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("anthropic", "claude-3-haiku-20240307") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.25),
        output_cost_per_million: Some(1.25),
        cache_read_cost_per_million: Some(0.03),
        cache_write_cost_per_million: Some(0.30),
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://platform.claude.com/docs/en/about-claude/pricing"),
        pricing_version: Some("anthropic-pricing-2026-05"),
        fetched_at: None,
      ))
    }
    #("deepseek", "deepseek-chat") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.14),
        output_cost_per_million: Some(0.28),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://api-docs.deepseek.com/quick_start/pricing"),
        pricing_version: Some("deepseek-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("deepseek", "deepseek-reasoner") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.55),
        output_cost_per_million: Some(2.19),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://api-docs.deepseek.com/quick_start/pricing"),
        pricing_version: Some("deepseek-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("deepseek", "deepseek-v4-pro") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(1.74),
        output_cost_per_million: Some(3.48),
        cache_read_cost_per_million: Some(0.0145),
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://api-docs.deepseek.com/quick_start/pricing"),
        pricing_version: Some("deepseek-pricing-2026-05-12"),
        fetched_at: None,
      ))
    }
    #("google", "gemini-2.5-pro") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(1.25),
        output_cost_per_million: Some(10.00),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://ai.google.dev/pricing"),
        pricing_version: Some("google-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("google", "gemini-2.5-flash") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.15),
        output_cost_per_million: Some(0.60),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://ai.google.dev/pricing"),
        pricing_version: Some("google-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("google", "gemini-2.0-flash") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.10),
        output_cost_per_million: Some(0.40),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://ai.google.dev/pricing"),
        pricing_version: Some("google-pricing-2026-03-16"),
        fetched_at: None,
      ))
    }
    #("bedrock", "anthropic.claude-opus-4-6") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(15.00),
        output_cost_per_million: Some(75.00),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://aws.amazon.com/bedrock/pricing/"),
        pricing_version: Some("bedrock-pricing-2026-04"),
        fetched_at: None,
      ))
    }
    #("bedrock", "anthropic.claude-sonnet-4-6")
    | #("bedrock", "anthropic.claude-sonnet-4-5") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(3.00),
        output_cost_per_million: Some(15.00),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://aws.amazon.com/bedrock/pricing/"),
        pricing_version: Some("bedrock-pricing-2026-04"),
        fetched_at: None,
      ))
    }
    #("bedrock", "anthropic.claude-haiku-4-5") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.80),
        output_cost_per_million: Some(4.00),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://aws.amazon.com/bedrock/pricing/"),
        pricing_version: Some("bedrock-pricing-2026-04"),
        fetched_at: None,
      ))
    }
    #("bedrock", "amazon.nova-pro") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.80),
        output_cost_per_million: Some(3.20),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://aws.amazon.com/bedrock/pricing/"),
        pricing_version: Some("bedrock-pricing-2026-04"),
        fetched_at: None,
      ))
    }
    #("bedrock", "amazon.nova-lite") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.06),
        output_cost_per_million: Some(0.24),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://aws.amazon.com/bedrock/pricing/"),
        pricing_version: Some("bedrock-pricing-2026-04"),
        fetched_at: None,
      ))
    }
    #("bedrock", "amazon.nova-micro") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.035),
        output_cost_per_million: Some(0.14),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: Some("https://aws.amazon.com/bedrock/pricing/"),
        pricing_version: Some("bedrock-pricing-2026-04"),
        fetched_at: None,
      ))
    }
    #("minimax", "minimax-m2.7") | #("minimax-cn", "minimax-m2.7") -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.30),
        output_cost_per_million: Some(1.20),
        cache_read_cost_per_million: None,
        cache_write_cost_per_million: None,
        request_cost: None,
        source: "official_docs_snapshot",
        source_url: None,
        pricing_version: Some("minimax-pricing-2026-04"),
        fetched_at: None,
      ))
    }
    #(_, _) -> None
  }
}

fn lookup_official_docs_pricing_route(route: BillingRoute) -> Option(PricingEntry) {
  let model = string.lowercase(route.model)
  case lookup_official_docs_pricing(route.provider, model) {
    Some(entry) -> Some(entry)
    None -> {
      case route.provider == "anthropic" {
        True -> {
          let normalized = normalize_anthropic_model_name(model)
          case normalized != model {
            True -> lookup_official_docs_pricing(route.provider, normalized)
            False -> None
          }
        }
        False -> None
      }
    }
  }
}

pub fn get_pricing_entry(
  model_name: String,
  provider provider: Option(String),
  base_url base_url: Option(String),
) -> Option(PricingEntry) {
  let route = resolve_billing_route(model_name, provider: provider, base_url: base_url)
  case route.billing_mode {
    "subscription_included" -> {
      Some(PricingEntry(
        input_cost_per_million: Some(0.0),
        output_cost_per_million: Some(0.0),
        cache_read_cost_per_million: Some(0.0),
        cache_write_cost_per_million: Some(0.0),
        request_cost: Some(0.0),
        source: "none",
        source_url: None,
        pricing_version: Some("included-route"),
        fetched_at: None,
      ))
    }
    _ -> {
      lookup_official_docs_pricing_route(route)
    }
  }
}

pub fn normalize_usage(
  response_usage: Dynamic,
  provider provider: Option(String),
  api_mode api_mode: Option(String),
) -> CanonicalUsage {
  let provider_name = string.lowercase(string.trim(option.unwrap(provider, "")))
  let mode = string.lowercase(string.trim(option.unwrap(api_mode, "")))

  case mode == "anthropic_messages" || provider_name == "anthropic" {
    True -> {
      let input_tokens = get_int_field(response_usage, "input_tokens")
      let output_tokens = get_int_field(response_usage, "output_tokens")
      let cache_read_tokens = get_int_field(response_usage, "cache_read_input_tokens")
      let cache_write_tokens = get_int_field(response_usage, "cache_creation_input_tokens")
      let reasoning_tokens = get_output_reasoning_tokens(response_usage)
      
      CanonicalUsage(
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cache_read_tokens: cache_read_tokens,
        cache_write_tokens: cache_write_tokens,
        reasoning_tokens: reasoning_tokens,
        request_count: 1,
      )
    }
    False -> {
      case mode == "codex_responses" {
        True -> {
          let input_total = get_int_field(response_usage, "input_tokens")
          let output_tokens = get_int_field(response_usage, "output_tokens")
          let details = get_field_dynamic(response_usage, "input_tokens_details")
          let cache_read_tokens = get_int_field(details, "cached_tokens")
          let cache_write_tokens = get_int_field(details, "cache_creation_tokens")
          let input_tokens = int.max(0, input_total - cache_read_tokens - cache_write_tokens)
          let reasoning_tokens = get_output_reasoning_tokens(response_usage)

          CanonicalUsage(
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_read_tokens: cache_read_tokens,
            cache_write_tokens: cache_write_tokens,
            reasoning_tokens: reasoning_tokens,
            request_count: 1,
          )
        }
        False -> {
          let prompt_total = get_int_field(response_usage, "prompt_tokens")
          let output_tokens = get_int_field(response_usage, "completion_tokens")
          let details = get_field_dynamic(response_usage, "prompt_tokens_details")
          
          let cache_read_tokens = case get_int_field(details, "cached_tokens") {
            0 -> get_int_field(response_usage, "cache_read_input_tokens")
            val -> val
          }
          let cache_write_tokens = case get_int_field(details, "cache_write_tokens") {
            0 -> get_int_field(response_usage, "cache_creation_input_tokens")
            val -> val
          }
          let input_tokens = int.max(0, prompt_total - cache_read_tokens - cache_write_tokens)
          let reasoning_tokens = get_output_reasoning_tokens(response_usage)

          CanonicalUsage(
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_read_tokens: cache_read_tokens,
            cache_write_tokens: cache_write_tokens,
            reasoning_tokens: reasoning_tokens,
            request_count: 1,
          )
        }
      }
    }
  }
}

pub fn estimate_usage_cost(
  model_name: String,
  usage: CanonicalUsage,
  provider provider: Option(String),
  base_url base_url: Option(String),
) -> CostResult {
  let route = resolve_billing_route(model_name, provider: provider, base_url: base_url)
  case route.billing_mode {
    "subscription_included" -> {
      CostResult(
        amount_usd: Some(0.0),
        status: "included",
        source: "none",
        label: "included",
        fetched_at: None,
        pricing_version: Some("included-route"),
        notes: [],
      )
    }
    _ -> {
      case get_pricing_entry(model_name, provider: provider, base_url: base_url) {
        None -> CostResult(
          amount_usd: None,
          status: "unknown",
          source: "none",
          label: "n/a",
          fetched_at: None,
          pricing_version: None,
          notes: [],
        )
        Some(entry) -> {
          let has_input_cost = case usage.input_tokens > 0 {
            True -> option.is_some(entry.input_cost_per_million)
            False -> True
          }
          let has_output_cost = case usage.output_tokens > 0 {
            True -> option.is_some(entry.output_cost_per_million)
            False -> True
          }
          let has_cache_read_cost = case usage.cache_read_tokens > 0 {
            True -> option.is_some(entry.cache_read_cost_per_million)
            False -> True
          }
          let has_cache_write_cost = case usage.cache_write_tokens > 0 {
            True -> option.is_some(entry.cache_write_cost_per_million)
            False -> True
          }

          case has_input_cost, has_output_cost, has_cache_read_cost, has_cache_write_cost {
            False, _, _, _ | _, False, _, _ -> {
              CostResult(
                amount_usd: None,
                status: "unknown",
                source: entry.source,
                label: "n/a",
                fetched_at: entry.fetched_at,
                pricing_version: entry.pricing_version,
                notes: [],
              )
            }
            _, _, False, _ -> {
              CostResult(
                amount_usd: None,
                status: "unknown",
                source: entry.source,
                label: "n/a",
                fetched_at: entry.fetched_at,
                pricing_version: entry.pricing_version,
                notes: ["cache-read pricing unavailable for route"],
              )
            }
            _, _, _, False -> {
              CostResult(
                amount_usd: None,
                status: "unknown",
                source: entry.source,
                label: "n/a",
                fetched_at: entry.fetched_at,
                pricing_version: entry.pricing_version,
                notes: ["cache-write pricing unavailable for route"],
              )
            }
            True, True, True, True -> {
              let amount = 0.0
              let amount = case entry.input_cost_per_million {
                Some(cost) -> amount +. int.to_float(usage.input_tokens) *. cost /. 1_000_000.0
                None -> amount
              }
              let amount = case entry.output_cost_per_million {
                Some(cost) -> amount +. int.to_float(usage.output_tokens) *. cost /. 1_000_000.0
                None -> amount
              }
              let amount = case entry.cache_read_cost_per_million {
                Some(cost) -> amount +. int.to_float(usage.cache_read_tokens) *. cost /. 1_000_000.0
                None -> amount
              }
              let amount = case entry.cache_write_cost_per_million {
                Some(cost) -> amount +. int.to_float(usage.cache_write_tokens) *. cost /. 1_000_000.0
                None -> amount
              }
              let amount = case entry.request_cost, usage.request_count > 0 {
                Some(cost), True -> amount +. int.to_float(usage.request_count) *. cost
                _, _ -> amount
              }

              let status = case entry.source == "none" && amount == 0.0 {
                True -> "included"
                False -> "estimated"
              }
              let label = case status {
                "included" -> "included"
                _ -> {
                  "~$" <> utils.format_float(amount)
                }
              }

              let notes = case route.provider == "openrouter" {
                True -> ["OpenRouter cost is estimated from the models API until reconciled."]
                False -> []
              }

              CostResult(
                amount_usd: Some(amount),
                status: status,
                source: entry.source,
                label: label,
                fetched_at: entry.fetched_at,
                pricing_version: entry.pricing_version,
                notes: notes,
              )
            }
          }
        }
      }
    }
  }
}

pub fn has_known_pricing(
  model_name: String,
  provider provider: Option(String),
  base_url base_url: Option(String),
) -> Bool {
  let route = resolve_billing_route(model_name, provider: provider, base_url: base_url)
  case route.billing_mode {
    "subscription_included" -> True
    _ -> {
      option.is_some(get_pricing_entry(model_name, provider: provider, base_url: base_url))
    }
  }
}

pub fn format_duration_compact(seconds: Float) -> String {
  case seconds <. 60.0 {
    True -> {
      int.to_string(float.round(seconds)) <> "s"
    }
    False -> {
      let minutes = seconds /. 60.0
      case minutes <. 60.0 {
        True -> {
          int.to_string(float.round(minutes)) <> "m"
        }
        False -> {
          let hours = minutes /. 60.0
          case hours <. 24.0 {
            True -> {
              let remaining_min = float.round(minutes) % 60
              let hrs = float.round(hours)
              case remaining_min {
                0 -> int.to_string(hrs) <> "h"
                _ -> int.to_string(hrs) <> "h " <> int.to_string(remaining_min) <> "m"
              }
            }
            False -> {
              let days = hours /. 24.0
              let rounded_days = int.to_float(float.round(days *. 10.0)) /. 10.0
              float.to_string(rounded_days) <> "d"
            }
          }
        }
      }
    }
  }
}

pub fn format_token_count_compact(value: Int) -> String {
  let abs_value = int.absolute_value(value)
  case abs_value < 1000 {
    True -> int.to_string(value)
    False -> {
      let sign = case value < 0 {
        True -> "-"
        False -> ""
      }
      
      let #(scaled, suffix) = case abs_value >= 1_000_000_000 {
        True -> #(int.to_float(abs_value) /. 1_000_000_000.0, "B")
        False -> {
          case abs_value >= 1_000_000 {
            True -> #(int.to_float(abs_value) /. 1_000_000.0, "M")
            False -> #(int.to_float(abs_value) /. 1000.0, "K")
          }
        }
      }
      
      let text = case scaled <. 10.0 {
        True -> {
          strip_trailing(utils.format_float(scaled))
        }
        False -> {
          case scaled <. 100.0 {
            True -> {
              let rounded = int.to_float(float.round(scaled *. 10.0)) /. 10.0
              strip_trailing(float.to_string(rounded))
            }
            False -> {
              int.to_string(float.round(scaled))
            }
          }
        }
      }
      sign <> text <> suffix
    }
  }
}

fn strip_trailing(s: String) -> String {
  let clean = case string.ends_with(s, "0") {
    True -> string.drop_end(s, 1)
    False -> s
  }
  let clean2 = case string.ends_with(clean, "0") {
    True -> string.drop_end(clean, 1)
    False -> clean
  }
  case string.ends_with(clean2, ".") {
    True -> string.drop_end(clean2, 1)
    False -> clean2
  }
}
