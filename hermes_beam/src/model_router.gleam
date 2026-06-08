import gleam/list
import gleam/option.{None, Some}
import gleam/string
import constants

// ─── Types ────────────────────────────────────────────────────────────────────

/// Maps directly from lm-eval-harness error categories to retry policy.
/// auth errors never retry (skip model), timeouts retry then skip, etc.
pub type FailureKind {
  /// 502, 503, conn refused, stream timeout → retry same model up to max_attempts
  InfraError
  /// 429, 402 rate-limited → back off then advance to next model
  RateLimit
  /// 401, 403 bad key → advance immediately, never retry this model
  AuthFailure
  /// 400, malformed request → don't retry (our bug, not infra)
  LogicError
  /// Catch-all
  Unknown
}

/// A prioritised list of model candidates with retry accounting.
/// Analogous to lm-eval's TemplateAPI: swap provider by changing the slug.
pub type ModelRouter {
  ModelRouter(
    /// Ordered list: [primary, fallback1, fallback2, ...]
    candidates: List(String),
    /// Index into candidates of the currently active model
    current_index: Int,
    /// How many consecutive failures on the current model
    attempt_on_current: Int,
    /// How many failures before advancing to the next model
    max_attempts_per_model: Int,
    /// Record of all failures for diagnostics
    failures: List(#(String, FailureKind)),
  )
}

// ─── Constructor ──────────────────────────────────────────────────────────────

/// Build a router from explicit primary + fallback list.
pub fn new(primary: String, fallbacks: List(String)) -> ModelRouter {
  ModelRouter(
    candidates: [primary, ..fallbacks],
    current_index: 0,
    attempt_on_current: 0,
    max_attempts_per_model: 2,
    failures: [],
  )
}

/// Build a router from environment variables.
/// Reads HERMES_MODEL (primary) and HERMES_FALLBACK_MODELS (comma-separated fallbacks).
pub fn from_env() -> ModelRouter {
  let primary = case constants.get_env("HERMES_MODEL") {
    Some(m) -> m
    None -> "openai/gpt-4o-mini"
  }
  let fallbacks = case constants.get_env("HERMES_FALLBACK_MODELS") {
    Some(raw) ->
      raw
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(s) { s != "" })
    None -> []
  }
  new(primary, fallbacks)
}

// ─── Accessors ────────────────────────────────────────────────────────────────

/// Return the currently active model slug.
pub fn current_model(router: ModelRouter) -> String {
  case list.drop(router.candidates, router.current_index) {
    [head, ..] -> head
    [] -> "openai/gpt-4o-mini"
  }
}

/// Number of candidates remaining (including current).
pub fn remaining_candidates(router: ModelRouter) -> Int {
  list.length(router.candidates) - router.current_index
}

// ─── Failure Handling ─────────────────────────────────────────────────────────

/// Record a failure for the current model.
/// Returns Ok(updated_router) with the same or advanced model.
/// Returns Error("all models exhausted") if no more candidates.
pub fn mark_failure(
  router: ModelRouter,
  kind: FailureKind,
) -> Result(ModelRouter, String) {
  let model = current_model(router)
  let updated_failures = [#(model, kind), ..router.failures]

  // Decide whether to advance immediately or retry
  let should_advance = case kind {
    // Auth failure: advance immediately, this key/model won't work
    AuthFailure -> True
    // Logic error: advance immediately, retrying same model won't help
    LogicError -> True
    // Rate limit / infra: retry up to max_attempts, then advance
    RateLimit | InfraError | Unknown ->
      router.attempt_on_current + 1 >= router.max_attempts_per_model
  }

  case should_advance {
    True -> {
      let next_index = router.current_index + 1
      let total = list.length(router.candidates)
      case next_index >= total {
        True -> Error("All models exhausted after " <> model)
        False ->
          Ok(ModelRouter(
            ..router,
            current_index: next_index,
            attempt_on_current: 0,
            failures: updated_failures,
          ))
      }
    }
    False ->
      Ok(ModelRouter(
        ..router,
        attempt_on_current: router.attempt_on_current + 1,
        failures: updated_failures,
      ))
  }
}

// ─── Display ──────────────────────────────────────────────────────────────────

/// Human-readable status for /status command.
pub fn status_line(router: ModelRouter) -> String {
  let model = current_model(router)
  let remaining = remaining_candidates(router)
  let attempt_info = case router.attempt_on_current {
    0 -> ""
    n -> " (attempt " <> int_to_str(n + 1) <> "/" <> int_to_str(router.max_attempts_per_model) <> ")"
  }
  let fallback_info = case remaining > 1 {
    True -> " → " <> int_to_str(remaining - 1) <> " fallback(s)"
    False -> " (last model)"
  }
  model <> attempt_info <> fallback_info
}

fn int_to_str(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    _ -> "N"
  }
}

/// Emoji prefix for each failure kind (matches lm-eval-harness error categories).
pub fn failure_emoji(kind: FailureKind) -> String {
  case kind {
    InfraError -> "🔌"
    RateLimit -> "💳"
    AuthFailure -> "🔐"
    LogicError -> "⚠️"
    Unknown -> "❓"
  }
}
