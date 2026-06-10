import gleam/list
import gleam/string
import model_router.{
  type FailureKind, AuthFailure, InfraError, LogicError, RateLimit, Unknown,
}

// ─── Error Classifier ─────────────────────────────────────────────────────────
//
// Inspired by lm-eval-harness per-error-type retry config:
//   - auth errors never retry (key won't fix itself)
//   - timeout / 502 / 503 retry then advance
//   - 429 rate-limit: back off then advance model
//   - 400 / malformed: don't retry (our bug)
//
// The model_router.FailureKind type is reused to keep concerns together.
// This module owns the string→kind mapping logic.

pub type ClassifiedError {
  ClassifiedError(kind: FailureKind, reason: String, emoji: String)
}

/// Classify a raw error string into a typed failure kind.
/// Input is typically the raw string from StreamError or HTTP response body.
pub fn classify(raw: String) -> ClassifiedError {
  let lower = string.lowercase(raw)

  let is_auth =
    list.any(
      [
        "401",
        "403",
        "invalid api key",
        "unauthorized",
        "authentication",
        "forbidden",
      ],
      string.contains(lower, _),
    )
  let is_rate =
    list.any(
      ["429", "402", "rate limit", "quota", "too many requests"],
      string.contains(lower, _),
    )
  let is_infra =
    list.any(
      [
        "502",
        "503",
        "504",
        "timeout",
        "connection refused",
        "econnrefused",
        "stream failed",
        "provider returned error",
        "model is unavailable",
      ],
      string.contains(lower, _),
    )
  let is_logic =
    list.any(
      ["400", "invalid model", "not a valid model", "not found"],
      string.contains(lower, _),
    )

  case is_auth, is_rate, is_infra, is_logic {
    True, _, _, _ -> make(AuthFailure, raw)
    False, True, _, _ -> make(RateLimit, raw)
    False, False, True, _ -> make(InfraError, raw)
    False, False, False, True -> make(LogicError, raw)
    _, _, _, _ -> make(Unknown, raw)
  }
}

fn make(kind: FailureKind, raw: String) -> ClassifiedError {
  ClassifiedError(
    kind: kind,
    reason: raw,
    emoji: model_router.failure_emoji(kind),
  )
}

/// Short label for display.
pub fn label(c: ClassifiedError) -> String {
  case c.kind {
    AuthFailure -> "Auth"
    RateLimit -> "Quota"
    InfraError -> "Infra"
    LogicError -> "Logic"
    Unknown -> "Unknown"
  }
}
