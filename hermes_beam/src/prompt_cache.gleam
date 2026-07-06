import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type CacheBackend {
  CacheBackend(
    provider: String,
    supports_cache_control: Bool,
    supports_header_cache: Bool,
  )
}

pub fn detect_provider(base_url: String) -> String {
  let lower = string.lowercase(base_url)
  case string.contains(lower, "anthropic") {
    True -> "anthropic"
    False ->
      case string.contains(lower, "openrouter") {
        True -> "openrouter"
        False ->
          case string.contains(lower, "openai.com") {
            True -> "openai"
            False ->
              case string.contains(lower, "dashscope") {
                True -> "qwen"
                False -> "generic"
              }
          }
      }
  }
}

pub fn detect_backend(base_url: String) -> CacheBackend {
  let provider = detect_provider(base_url)
  case provider {
    "anthropic" ->
      CacheBackend(
        provider: provider,
        supports_cache_control: True,
        supports_header_cache: False,
      )
    "openrouter" ->
      CacheBackend(
        provider: provider,
        supports_cache_control: False,
        supports_header_cache: True,
      )
    "qwen" ->
      CacheBackend(
        provider: provider,
        supports_cache_control: False,
        supports_header_cache: True,
      )
    "openai" ->
      CacheBackend(
        provider: provider,
        supports_cache_control: False,
        supports_header_cache: True,
      )
    _ ->
      CacheBackend(
        provider: provider,
        supports_cache_control: False,
        supports_header_cache: False,
      )
  }
}

pub fn cache_headers(backend: CacheBackend) -> List(#(String, String)) {
  case backend.supports_header_cache {
    True -> case backend.provider {
      "openrouter" -> [#("X-OpenRouter-Cache-TTL", "300")]
      "qwen" -> []
      _ -> []
    }
    False -> []
  }
}

pub fn anthropic_beta_headers() -> List(#(String, String)) {
  [
    #(
      "anthropic-beta",
      "max-tokens-3-5-sonnet-2024-07-15,prompt-caching-2024-07-31",
    ),
  ]
}

pub fn should_add_cache_marker(
  backend: CacheBackend,
  message_count: Int,
) -> Bool {
  case backend.supports_cache_control {
    False -> False
    True -> message_count >= 4
  }
}

pub fn inject_cache_markers(
  messages: List(#(String, String, Option(String))),
  backend: CacheBackend,
) -> List(#(String, String, Option(String))) {
  case backend.supports_cache_control {
    False -> messages
    True -> {
      let count = list.length(messages)
      case should_add_cache_marker(backend, count) {
        False -> messages
        True -> {
          let reversed = list.reverse(messages)
          case reversed {
            [] -> messages
            [last, ..rest] -> {
              let updated = #(last.0, last.1, Some("ephemeral"))
              let second_updated = case rest {
                [second, ..tail] -> {
                  let su = #(second.0, second.1, Some("ephemeral"))
                  list.reverse([su, ..tail]) |> list.append([updated])
                }
                _ -> [updated]
              }
              second_updated
            }
          }
        }
      }
    }
  }
}

pub fn cache_enabled_for_provider(
  base_url: String,
  env_override: Option(String),
) -> Bool {
  case env_override {
    Some(val) -> {
      case string.lowercase(string.trim(val)) {
        "false" | "0" | "no" | "off" -> False
        _ -> True
      }
    }
    None -> {
      let backend = detect_backend(base_url)
      case backend.provider {
        "generic" -> False
        _ -> True
      }
    }
  }
}

pub fn provider_context(base_url: String) -> #(String, CacheBackend) {
  let backend = detect_backend(base_url)
  #(backend.provider, backend)
}
