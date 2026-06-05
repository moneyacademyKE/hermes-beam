import constants
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/string
import hermes_agent
import hermes_exec
import hermes_state
import sqlight
import utils

// ─── REPL State ───────────────────────────────────────────────────────────────

pub type REPLState {
  REPLState(
    session_id: String,
    model: String,
    cwd: String,
    db_conn: sqlight.Connection,
    exec_env: hermes_exec.TerminalEnv,
    api_key: String,
    base_url: String,
    agent_state: hermes_agent.AgentState,
  )
}

@external(erlang, "timer", "sleep")
pub fn sleep_ms(ms: Int) -> Nil

// ─── Credential Resolution ─────────────────────────────────────────────────────

pub fn resolve_api_credentials() -> #(String, String) {
  let key =
    case constants.get_env("HERMES_API_KEY") {
      Some(val) -> val
      None ->
        case constants.get_env("OPENROUTER_API_KEY") {
          Some(val) -> val
          None ->
            case constants.get_env("OPENAI_API_KEY") {
              Some(val) -> val
              None -> ""
            }
        }
    }

  let url =
    case constants.get_env("HERMES_BASE_URL") {
      Some(val) -> val
      None ->
        case constants.get_env("OPENAI_BASE_URL") {
          Some(val) -> val
          None -> "https://openrouter.ai/api/v1"
        }
    }

  #(key, url)
}

// ─── Help ─────────────────────────────────────────────────────────────────────

pub fn print_help() -> Nil {
  io.println("\nHermes BEAM interactive REPL commands:")
  io.println("  /help          - Show this help message")
  io.println("  /quit, /exit   - Close the session and exit")
  io.println("  /model <model> - Switch the current model (resets agent history)")
  io.println("  /cwd <path>    - Switch the working directory")
  io.println("  /run <cmd>     - Execute a terminal command directly (bypasses LLM)")
  io.println("  /clear         - Clear the conversation history")
  io.println("  <message>      - Chat with the LLM agent (tools available)")
}

// ─── Mock completion (when no API key) ────────────────────────────────────────

pub fn run_mock_completion(prompt: String) -> String {
  let response =
    "I am running in local mock completion mode. You asked: \""
    <> prompt
    <> "\". To connect to a live LLM, configure HERMES_API_KEY, OPENROUTER_API_KEY, or OPENAI_API_KEY."
  type_out_string(response)
  response
}

fn type_out_string(s: String) -> Nil {
  case string.pop_grapheme(s) {
    Ok(#(char, rest)) -> {
      io.print(char)
      let _ = sleep_ms(12)
      type_out_string(rest)
    }
    Error(_) -> {
      io.println("")
      Nil
    }
  }
}

// ─── REPL Loop ────────────────────────────────────────────────────────────────

pub fn repl_loop(state: REPLState) -> Nil {
  let prompt =
    "\nhermes_beam ["
    <> state.model
    <> "] ("
    <> state.cwd
    <> ") > "

  case utils.read_line(prompt) {
    Ok(line) -> {
      let trimmed = string.trim(line)
      let is_quit = trimmed == "/quit" || trimmed == "/exit"
      let is_help = trimmed == "/help"
      let is_model = string.starts_with(trimmed, "/model ")
      let is_cwd = string.starts_with(trimmed, "/cwd ")
      let is_run = string.starts_with(trimmed, "/run ")
      let is_clear = trimmed == "/clear"

      case trimmed {
        // ── Empty input ─────────────────────────────────────────────────────
        "" -> repl_loop(state)

        // ── /quit ───────────────────────────────────────────────────────────
        _ if is_quit -> {
          io.println("Cleaning up terminal environment...")
          let _ = hermes_exec.cleanup(state.exec_env)
          let timestamp = 1_700_000_000.0
          let _ =
            hermes_state.end_session(
              state.db_conn,
              state.session_id,
              "user_quit",
              timestamp,
            )
          let _ = sqlight.close(state.db_conn)
          io.println("Goodbye!")
          Nil
        }

        // ── /help ───────────────────────────────────────────────────────────
        _ if is_help -> {
          print_help()
          repl_loop(state)
        }

        // ── /clear ──────────────────────────────────────────────────────────
        _ if is_clear -> {
          io.println("Conversation history cleared.")
          // Build a fresh agent state with same config but empty history
          let new_agent_state =
            hermes_agent.new_agent_state(
              state.session_id,
              state.model,
              state.cwd,
              state.db_conn,
              state.exec_env,
              state.api_key,
              state.base_url,
              "You are a helpful assistant with access to shell tools.",
              90,
            )
          case new_agent_state {
            Ok(new_agent) ->
              repl_loop(REPLState(..state, agent_state: new_agent))
            Error(_) -> repl_loop(state)
          }
        }

        // ── /model <name> ────────────────────────────────────────────────────
        _ if is_model -> {
          let new_model = string.trim(string.drop_start(trimmed, 7))
          let _ =
            hermes_state.create_session(
              state.db_conn,
              state.session_id,
              "repl",
              new_model,
              "You are a helpful assistant.",
              1_700_000_000.0,
            )
          io.println("Switched model to: " <> new_model)
          // Build fresh agent with new model
          let new_agent_state =
            hermes_agent.new_agent_state(
              state.session_id,
              new_model,
              state.cwd,
              state.db_conn,
              state.exec_env,
              state.api_key,
              state.base_url,
              "You are a helpful assistant with access to shell tools.",
              90,
            )
          case new_agent_state {
            Ok(new_agent) ->
              repl_loop(REPLState(
                ..state,
                model: new_model,
                agent_state: new_agent,
              ))
            Error(_) -> repl_loop(REPLState(..state, model: new_model))
          }
        }

        // ── /cwd <path> ──────────────────────────────────────────────────────
        _ if is_cwd -> {
          let new_cwd = string.trim(string.drop_start(trimmed, 5))
          let new_exec_env =
            hermes_exec.TerminalEnv(..state.exec_env, cwd: new_cwd)
          let _ =
            hermes_state.update_session_cwd(
              state.db_conn,
              state.session_id,
              new_cwd,
            )
          io.println("Switched directory to: " <> new_cwd)
          repl_loop(
            REPLState(..state, cwd: new_cwd, exec_env: new_exec_env),
          )
        }

        // ── /run <cmd> ───────────────────────────────────────────────────────
        _ if is_run -> {
          let cmd = string.trim(string.drop_start(trimmed, 5))
          io.println("[Executing: " <> cmd <> "]")
          let #(new_exec_env, result) =
            hermes_exec.execute(state.exec_env, cmd, "", None)
          case result {
            Ok(#(output, status)) -> {
              io.print(output)
              io.println("[Exit code: " <> int.to_string(status) <> "]")
              let _ =
                hermes_state.update_session_cwd(
                  state.db_conn,
                  state.session_id,
                  new_exec_env.cwd,
                )
              repl_loop(
                REPLState(
                  ..state,
                  cwd: new_exec_env.cwd,
                  exec_env: new_exec_env,
                ),
              )
            }
            Error(err) -> {
              io.println("Execution Error: " <> err)
              repl_loop(REPLState(..state, exec_env: new_exec_env))
            }
          }
        }

        // ── LLM prompt via agent loop ─────────────────────────────────────────
        _ -> {
          case state.api_key == "" {
            True -> {
              let _response = run_mock_completion(trimmed)
              repl_loop(state)
            }
            False -> {
              case hermes_agent.run_conversation(state.agent_state, trimmed) {
                Ok(new_agent) -> {
                  // Sync CWD back from agent exec_env in case tools changed it
                  let new_cwd = new_agent.exec_env.cwd
                  let _ =
                    hermes_state.update_session_cwd(
                      state.db_conn,
                      state.session_id,
                      new_cwd,
                    )
                  repl_loop(
                    REPLState(
                      ..state,
                      cwd: new_cwd,
                      exec_env: new_agent.exec_env,
                      agent_state: new_agent,
                    ),
                  )
                }
                Error(err) -> {
                  io.println("\n[Agent Error: " <> err <> "]")
                  repl_loop(state)
                }
              }
            }
          }
        }
      }
    }

    // EOF / read error → clean exit
    Error(_) -> Nil
  }
}

// ─── Entry Point ──────────────────────────────────────────────────────────────

pub fn main() -> Nil {
  io.println("══════════════════════════════════════════════════")
  io.println("  Hermes BEAM — Pure Gleam Agentic Runner v2.0.0")
  io.println("══════════════════════════════════════════════════")

  // 1. Initialize database
  let db_path = constants.path_join(constants.get_hermes_home(), "state.db")
  let assert Ok(conn) = hermes_state.connect(db_path)
  let assert Ok(Nil) = hermes_state.init_schema(conn)

  // 2. Load credentials
  let #(api_key, base_url) = resolve_api_credentials()
  let model =
    case constants.get_env("HERMES_MODEL") {
      Some(val) -> val
      None -> "meta-llama/llama-3-8b-instruct:free"
    }

  // 3. Create session
  let session_id = hermes_exec.generate_uuid()
  let assert Ok(Nil) =
    hermes_state.create_session(
      conn,
      session_id,
      "repl",
      model,
      "You are a helpful assistant with access to shell tools.",
      1_700_000_000.0,
    )

  // 4. Initialize sandbox exec environment
  let initial_cwd = hermes_exec.get_temp_dir()
  let exec_env = hermes_exec.new_terminal_env(initial_cwd, 120_000, [])
  let exec_env = hermes_exec.init_session(exec_env)

  io.println("Session ID : " <> session_id)
  io.println("Database   : " <> db_path)
  io.println("Model      : " <> model)
  io.println("Base URL   : " <> base_url)
  io.println(
    "API Key    : "
    <> case api_key == "" {
      True -> "(none — mock mode)"
      False -> "[configured]"
    },
  )
  io.println("CWD        : " <> exec_env.cwd)
  io.println("\nType /help to see commands. Press Ctrl+D or /quit to exit.")

  // 5. Build initial AgentState (max 90 iterations per conversation turn)
  let agent_result =
    hermes_agent.new_agent_state(
      session_id,
      model,
      exec_env.cwd,
      conn,
      exec_env,
      api_key,
      base_url,
      "You are a helpful assistant with access to shell tools. When you need to run a command, use the run_command tool. When you need to read a file, use read_file. When you need to write a file, use write_file.",
      90,
    )

  case agent_result {
    Error(err) -> {
      io.println("Failed to initialise agent: " <> err)
      Nil
    }
    Ok(agent_state) -> {
      let state =
        REPLState(
          session_id: session_id,
          model: model,
          cwd: exec_env.cwd,
          db_conn: conn,
          exec_env: exec_env,
          api_key: api_key,
          base_url: base_url,
          agent_state: agent_state,
        )

      repl_loop(state)
    }
  }
}
