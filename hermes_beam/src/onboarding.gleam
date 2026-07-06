import constants
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import simplifile
import utils

pub type OnboardingStep {
  CheckHome
  CheckCredentials
  CheckBabashka
  CheckTelegram
  CheckMemoryBackend
  CheckCompaction
  WriteConfig
  Done
}

pub type OnboardingState {
  OnboardingState(
    api_key: String,
    base_url: String,
    model: String,
    memory_backend: String,
    enable_compaction: Bool,
    telegram_token: String,
    completed: List(OnboardingStep),
  )
}

pub fn new_state() -> OnboardingState {
  OnboardingState(
    api_key: "",
    base_url: "https://openrouter.ai/api/v1",
    model: "openai/gpt-4o-mini",
    memory_backend: "",
    enable_compaction: True,
    telegram_token: "",
    completed: [],
  )
}

fn read_line_default(prompt: String, default: String) -> String {
  case utils.read_line(prompt) {
    Ok(v) ->
      case string.trim(v) {
        "" -> default
        other -> other
      }
    Error(_) -> default
  }
}

pub fn run_onboarding() -> OnboardingState {
  io.println("══════════════════════════════════════════════════")
  io.println("  Hermes BEAM — Onboarding Wizard")
  io.println("══════════════════════════════════════════════════\n")

  let state = new_state()
  let state = step_credentials(state)
  let state = step_model(state)
  let state = step_memory(state)
  let state = step_compaction(state)
  let state = step_telegram(state)
  let state = step_summary(state)
  let _ = write_config_file(state)
  io.println("\n✓ Onboarding complete! Configuration written to ~/.hermes/.env")
  io.println("  Run 'hermes' or 'gleam run' to start.\n")
  state
}

fn step_credentials(state: OnboardingState) -> OnboardingState {
  io.println("── Step 1: LLM Credentials ──────────────────────")
  io.println("Hermes needs an OpenAI-compatible API key.")
  io.println("Common providers: OpenRouter, OpenAI, Anthropic\n")

  let existing_key = case constants.get_env("HERMES_API_KEY") {
    Some(k) if k != "" -> k
    _ -> case constants.get_env("OPENROUTER_API_KEY") {
      Some(k) -> k
      _ -> case constants.get_env("OPENAI_API_KEY") {
        Some(k) -> k
        _ -> ""
      }
    }
  }

  case existing_key == "" {
    False -> {
      io.println("Found existing API key. Using it.")
      OnboardingState(..state, api_key: existing_key)
    }
    True -> {
      let key = string.trim(read_line_default("Enter your API key: ", ""))
      case key == "" {
        True -> {
          io.println("  ⚠ No key provided — REPL will use mock mode.")
          state
        }
        False -> OnboardingState(..state, api_key: key)
      }
    }
  }
}

fn step_model(state: OnboardingState) -> OnboardingState {
  io.println("\n── Step 2: Model Selection ───────────────────────")
  io.println("Default model: " <> state.model)
  io.println("Examples: openai/gpt-4o-mini, anthropic/claude-3.5-sonnet, meta-llama/llama-3.1-70b")

  let model = string.trim(
    read_line_default("Model [" <> state.model <> "]: ", state.model),
  )
  let url = case string.contains(string.lowercase(model), "claude") {
    True -> "https://api.anthropic.com/v1"
    False -> state.base_url
  }
  OnboardingState(..state, model: model, base_url: url)
}

fn step_memory(state: OnboardingState) -> OnboardingState {
  io.println("\n── Step 3: Memory Backend ────────────────────────")
  io.println("Memory backends: gleamdb (local Datalog), honcho, mem0, supermemory")
  io.println("Leave empty to disable memory injection.\n")

  let backend = string.trim(
    read_line_default("Memory backend [gleamdb]: ", "gleamdb"),
  )
  OnboardingState(..state, memory_backend: backend)
}

fn step_compaction(state: OnboardingState) -> OnboardingState {
  io.println("\n── Step 4: Context Compaction ────────────────────")
  io.println("Auto-compaction summarizes old context to keep sessions running.")
  io.println("Default: soft at 65%, hard at 90% of context window.\n")

  let choice = string.trim(
    read_line_default("Enable auto-compaction? [Y/n]: ", "Y"),
  )
  let enabled = case string.lowercase(choice) {
    "n" | "no" -> False
    _ -> True
  }
  OnboardingState(..state, enable_compaction: enabled)
}

fn step_telegram(state: OnboardingState) -> OnboardingState {
  io.println("\n── Step 5: Telegram Gateway (optional) ───────────")
  io.println("Connect Hermes to Telegram for remote agent access.\n")

  let choice = string.trim(
    read_line_default("Configure Telegram? [y/N]: ", "N"),
  )
  case string.lowercase(choice) {
    "y" | "yes" -> {
      let token = string.trim(
        read_line_default("Telegram bot token: ", ""),
      )
      OnboardingState(..state, telegram_token: token)
    }
    _ -> state
  }
}

fn step_summary(state: OnboardingState) -> OnboardingState {
  io.println("\n── Configuration Summary ─────────────────────────")
  io.println("  API Key  : " <> mask_key(state.api_key))
  io.println("  Base URL : " <> state.base_url)
  io.println("  Model    : " <> state.model)
  io.println("  Memory   : " <> case state.memory_backend {
    "" -> "disabled"
    b -> b
  })
  io.println("  Compact  : " <> case state.enable_compaction {
    True -> "enabled (65%/90%)"
    False -> "disabled"
  })
  io.println("  Telegram : " <> case state.telegram_token {
    "" -> "not configured"
    _ -> "configured"
  })
  io.println("")

  let confirm = string.trim(read_line_default("Save configuration? [Y/n]: ", "Y"))
  case string.lowercase(confirm) {
    "n" | "no" -> {
      io.println("Configuration not saved.")
      state
    }
    _ -> state
  }
}

fn write_config_file(state: OnboardingState) -> Result(Nil, String) {
  let home = constants.get_hermes_home()
  let _ = simplifile.create_directory_all(home)
  let env_path = constants.path_join(home, ".env")

  let lines = [
    "# Hermes BEAM configuration (generated by onboarding)",
    "HERMES_HOME=" <> home,
    "HERMES_API_KEY=" <> state.api_key,
    "HERMES_BASE_URL=" <> state.base_url,
    "HERMES_MODEL=" <> state.model,
    case state.memory_backend {
      "" -> "HERMES_MEMORY_BACKEND="
      b -> "HERMES_MEMORY_BACKEND=" <> b
    },
    "HERMES_ENABLE_SEMANTIC_SEARCH=" <> case state.memory_backend {
      "" -> "false"
      _ -> "true"
    },
    "HERMES_TOKEN_BUDGET=200000",
    "HERMES_STREAM_TIMEOUT_MS=120000",
  ]

  let content = string.join(lines, with: "\n")
  simplifile.write(env_path, content)
  |> result.map_error(fn(_) { "Failed to write config file" })
}

fn mask_key(key: String) -> String {
  case key {
    "" -> "(not set)"
    _ -> {
      let len = string.length(key)
      case len <= 8 {
        True -> string.repeat("*", len)
        False -> string.slice(key, 0, 4) <> string.repeat("*", 4) <> string.slice(key, len - 4, 4)
      }
    }
  }
}
