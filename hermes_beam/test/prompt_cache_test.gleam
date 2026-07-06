import gleam/list
import gleam/option
import prompt_cache

pub fn prompt_cache_detect_anthropic_test() {
  let backend = prompt_cache.detect_backend("https://api.anthropic.com/v1")
  let assert "anthropic" = test_provider(backend)
  let assert True = test_supports_cache(backend)
}

pub fn prompt_cache_detect_openrouter_test() {
  let backend = prompt_cache.detect_backend("https://openrouter.ai/api/v1")
  let assert "openrouter" = test_provider(backend)
  let assert True = test_supports_header(backend)
}

pub fn prompt_cache_detect_openai_test() {
  let backend = prompt_cache.detect_backend("https://api.openai.com/v1")
  let assert "openai" = test_provider(backend)
  let assert True = test_supports_header(backend)
}

pub fn prompt_cache_detect_generic_test() {
  let backend = prompt_cache.detect_backend("https://custom-llm.example.com/v1")
  let assert "generic" = test_provider(backend)
  let assert False = test_supports_cache(backend)
  let assert False = test_supports_header(backend)
}

pub fn prompt_cache_openrouter_headers_test() {
  let backend = prompt_cache.detect_backend("https://openrouter.ai/api/v1")
  let headers = prompt_cache.cache_headers(backend)
  let assert True = list_contains(headers, #("X-OpenRouter-Cache-TTL", "300"))
}

pub fn prompt_cache_generic_headers_test() {
  let backend = prompt_cache.CacheBackend(
    provider: "generic",
    supports_cache_control: False,
    supports_header_cache: False,
  )
  let headers = prompt_cache.cache_headers(backend)
  let assert 0 = list.length(headers)
}

pub fn prompt_cache_anthropic_beta_headers_test() {
  let headers = prompt_cache.anthropic_beta_headers()
  let assert True = list.length(headers) > 0
}

pub fn prompt_cache_should_add_marker_test() {
  let backend = prompt_cache.detect_backend("https://api.anthropic.com/v1")
  let assert False = prompt_cache.should_add_cache_marker(backend, 2)
  let assert True = prompt_cache.should_add_cache_marker(backend, 4)
  let assert True = prompt_cache.should_add_cache_marker(backend, 10)
}

pub fn prompt_cache_enabled_for_provider_test() {
  let assert True = prompt_cache.cache_enabled_for_provider(
    "https://api.anthropic.com/v1",
    option.None,
  )
  let assert False = prompt_cache.cache_enabled_for_provider(
    "https://custom.example.com/v1",
    option.None,
  )
  let assert False = prompt_cache.cache_enabled_for_provider(
    "https://api.anthropic.com/v1",
    option.Some("false"),
  )
}

pub fn prompt_cache_provider_context_test() {
  let #(provider, backend) =
    prompt_cache.provider_context("https://api.anthropic.com/v1")
  let assert "anthropic" = provider
  let assert True = test_supports_cache(backend)
}

fn test_provider(b: prompt_cache.CacheBackend) -> String {
  let prompt_cache.CacheBackend(provider: p, ..) = b
  p
}

fn test_supports_cache(b: prompt_cache.CacheBackend) -> Bool {
  let prompt_cache.CacheBackend(supports_cache_control: s, ..) = b
  s
}

fn test_supports_header(b: prompt_cache.CacheBackend) -> Bool {
  let prompt_cache.CacheBackend(supports_header_cache: s, ..) = b
  s
}

fn list_contains(list: List(a), item: a) -> Bool {
  case list {
    [] -> False
    [h, ..rest] -> case h == item {
      True -> True
      False -> list_contains(rest, item)
    }
  }
}
