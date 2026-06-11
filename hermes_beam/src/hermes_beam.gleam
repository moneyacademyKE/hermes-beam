import argv
import constants
import context_engine
import datom.{type Datom, Datom, Rule}
import discord_gateway
import evolutionary
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import hermes_agent
import hermes_exec
import hermes_state
import mcp_client
import simplifile
import skill.{Skill}
import skill_compiler
import state_actor
import subagent_supervisor
import utils

@external(erlang, "erlang", "system_time")
fn system_time() -> Int

pub fn get_default_prompt() -> String {
  "You are a helpful assistant. CRITICAL RULE: You MUST default to using Babashka (bb) for any task that requires scripting. NO PYTHON SHOULD EVER BE INVOKED. Perform a thorough and comprehensive Rich Hickey Gap Analysis. Search the web to learn all the capabilities including those of latest versions. Use tables to show feature set differences. Explain each feature difference. Show benefits and trade offs. Show complexity vs utility tables. End with actionable recommendation based on weighted power/new capabilites vs speed vs complexity vs tradeoffs analysis. Use its recomended actions next for implementation. when having open questions use rich hickey path. red/green tdd. When implementing ensure Rich Hickey quality and completeness at every step. finish by ensuring rich hickey certification. add new content to docs , git and learnings.md and patterns as .md when done. learnings and patterns should be constantly updated and refered to when dealing with similar problems."
}

pub fn get_tools_prompt() -> String {
  "You are a helpful assistant with access to shell tools. When you need to run a command, use the run_command tool. When you need to read a file, use read_file. When you need to write a file, use write_file. CRITICAL RULE: You MUST default to using Babashka (bb) for any task that requires scripting. NO PYTHON SHOULD EVER BE INVOKED. Perform a thorough and comprehensive Rich Hickey Gap Analysis. Search the web to learn all the capabilities including those of latest versions. Use tables to show feature set differences. Explain each feature difference. Show benefits and trade offs. Show complexity vs utility tables. End with actionable recommendation based on weighted power/new capabilites vs speed vs complexity vs tradeoffs analysis. Use its recomended actions next for implementation. when having open questions use rich hickey path. red/green tdd. When implementing ensure Rich Hickey quality and completeness at every step. finish by ensuring rich hickey certification. add new content to docs , git and learnings.md and patterns as .md when done. learnings and patterns should be constantly updated and refered to when dealing with similar problems."
}

pub fn get_goal_prompt(goal: String) -> String {
  let dynamic_context =
    context_engine.execute_all(context_engine.default_plugins())
  let prompt_with_context = case dynamic_context {
    "" -> goal
    ctx -> goal <> "\n\n<context>\n" <> ctx <> "\n</context>"
  }
  "GOAL MODE ENGAGED. You must act completely autonomously. Do not ask for user input. Continue calling tools until the goal is completely achieved. If you hit a roadblock, keep trying different approaches. CRITICAL RULE: You MUST default to using Babashka (bb) for any task that requires scripting. NO PYTHON SHOULD EVER BE INVOKED. Perform a thorough and comprehensive Rich Hickey Gap Analysis. Search the web to learn all the capabilities including those of latest versions. Use tables to show feature set differences. Explain each feature difference. Show benefits and trade offs. Show complexity vs utility tables. End with actionable recommendation based on weighted power/new capabilites vs speed vs complexity vs tradeoffs analysis. Use its recomended actions next for implementation. when having open questions use rich hickey path. red/green tdd. When implementing ensure Rich Hickey quality and completeness at every step. finish by ensuring rich hickey certification. add new content to docs , git and learnings.md and patterns as .md when done. learnings and patterns should be constantly updated and refered to when dealing with similar problems.\n\nGoal: "
  <> prompt_with_context
}

// ─── REPL State ───────────────────────────────────────────────────────────────

pub type REPLState {
  REPLState(
    session_id: String,
    model: String,
    cwd: String,
    db_conn: state_actor.StateActor,
    exec_env: hermes_exec.TerminalEnv,
    api_key: String,
    base_url: String,
    agent_state: hermes_agent.AgentState,
  )
}

pub type IntentLoopInit {
  IntentLoopInit(
    mcp_client_opt: option.Option(mcp_client.McpClient),
    supervisor_subj: process.Subject(subagent_supervisor.SupervisorMessage),
    agent_state: hermes_agent.AgentState,
  )
}

pub type SpawnedSubjects {
  SpawnedSubjects(
    intent_subj: process.Subject(Datom),
    init_subj: process.Subject(IntentLoopInit),
  )
}

@external(erlang, "timer", "sleep")
pub fn sleep_ms(ms: Int) -> Nil

// ─── Credential Resolution ─────────────────────────────────────────────────────

pub fn resolve_api_credentials() -> #(String, String) {
  let key = case constants.get_env("HERMES_API_KEY") {
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

  let url = case constants.get_env("HERMES_BASE_URL") {
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
  io.println(
    "  /model <model> - Switch the current model (resets agent history)",
  )
  io.println("  /cwd <path>    - Switch the working directory")
  io.println(
    "  /run <cmd>     - Execute a terminal command directly (bypasses LLM)",
  )
  io.println(
    "  /file <path>   - Load a prompt from a file and send to LLM agent",
  )
  io.println("  /clear         - Clear the conversation history")
  io.println("  /sessions      - List recent sessions for resumability")
  io.println("  /resume <id>   - Resume a past session")
  io.println(
    "  /rollback <n>  - Undo the last N messages from memory and database",
  )
  io.println(
    "  /search <term> - Search past messages across all sessions (FTS5)",
  )
  io.println(
    "  /goal <prompt> - Run an autonomous long-running task until finished",
  )
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

pub fn log_event(msg: String) -> Nil {
  let log_dir = constants.path_join(constants.get_hermes_home(), "logs")
  let _ = simplifile.create_directory_all(log_dir)
  let log_path = constants.path_join(log_dir, "agent.log")
  let _ = simplifile.append(log_path, msg <> "\n")
  Nil
}

// ─── REPL Loop ────────────────────────────────────────────────────────────────

pub fn repl_loop(state: REPLState) -> Nil {
  let prompt = "\nhermes_beam [" <> state.model <> "] (" <> state.cwd <> ") > "

  case utils.read_line(prompt) {
    Ok(line) -> {
      let trimmed = string.trim(line)
      let is_quit = trimmed == "/quit" || trimmed == "/exit"
      let is_help = trimmed == "/help"
      let is_model = string.starts_with(trimmed, "/model ")
      let is_cwd = string.starts_with(trimmed, "/cwd ")
      let is_run = string.starts_with(trimmed, "/run ")
      let is_file = string.starts_with(trimmed, "/file ")
      let is_clear = trimmed == "/clear"
      let is_sessions = trimmed == "/sessions"
      let is_resume = string.starts_with(trimmed, "/resume ")
      let is_rollback = string.starts_with(trimmed, "/rollback ")
      let is_search = string.starts_with(trimmed, "/search ")
      let is_goal = string.starts_with(trimmed, "/goal ")

      case trimmed {
        // ── Empty input ─────────────────────────────────────────────────────
        "" -> repl_loop(state)

        // ── /quit ───────────────────────────────────────────────────────────
        _ if is_quit -> {
          io.println("Cleaning up terminal environment...")
          let _ = hermes_exec.cleanup(state.exec_env)
          let timestamp = 1_700_000_000.0
          let _ =
            state_actor.end_session(
              state.db_conn,
              state.session_id,
              "user_quit",
              timestamp,
            )
          let _ = state_actor.close(state.db_conn)
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
              get_tools_prompt(),
              90,
              option.None,
            )
          case new_agent_state {
            Ok(new_agent) ->
              repl_loop(REPLState(..state, agent_state: new_agent))
            Error(_) -> repl_loop(state)
          }
        }

        // ── /sessions ────────────────────────────────────────────────────────
        _ if is_sessions -> {
          case state_actor.list_sessions(state.db_conn) {
            Ok(sessions) -> {
              io.println("Recent Sessions:")
              list.each(list.take(sessions, 10), fn(s) {
                io.println("  - " <> s)
              })
            }
            Error(err) ->
              io.println("Error listing sessions: " <> string.inspect(err))
          }
          repl_loop(state)
        }

        // ── /resume <id> ──────────────────────────────────────────────────────
        _ if is_resume -> {
          let resume_id = string.trim(string.drop_start(trimmed, 8))
          case state_actor.get_session_history(state.db_conn, resume_id) {
            Ok(history_strings) -> {
              io.println("Resuming session: " <> resume_id)
              // Note history from DB is oldest-first, so we reverse it for the in-memory state which expects newest-first list head
              let new_agent =
                hermes_agent.AgentState(
                  ..state.agent_state,
                  session_id: resume_id,
                  history: list.reverse(history_strings),
                )
              repl_loop(
                REPLState(
                  ..state,
                  session_id: resume_id,
                  agent_state: new_agent,
                ),
              )
            }
            Error(err) -> {
              io.println("Failed to load session: " <> string.inspect(err))
              repl_loop(state)
            }
          }
        }

        // ── /rollback <n> ────────────────────────────────────────────────────
        _ if is_rollback -> {
          let count_str = string.trim(string.drop_start(trimmed, 10))
          case int.parse(count_str) {
            Ok(n) -> {
              let _ =
                state_actor.rollback_session(state.db_conn, state.session_id, n)
              let new_history = list.drop(state.agent_state.history, n)
              io.println("Rolled back " <> int.to_string(n) <> " messages.")
              let new_agent =
                hermes_agent.AgentState(
                  ..state.agent_state,
                  history: new_history,
                )
              repl_loop(REPLState(..state, agent_state: new_agent))
            }
            Error(_) -> {
              io.println("Invalid number for rollback.")
              repl_loop(state)
            }
          }
        }

        // ── /search <term> ──────────────────────────────────────────────────
        _ if is_search -> {
          let term = string.trim(string.drop_start(trimmed, 8))
          case state_actor.search_messages(state.db_conn, term) {
            Ok(matches) -> {
              case matches {
                [] -> io.println("No results for: " <> term)
                results -> {
                  io.println(
                    "Found "
                    <> int.to_string(list.length(results))
                    <> " result(s):",
                  )
                  list.each(list.take(results, 10), fn(m) {
                    io.println(
                      "  ["
                      <> m.session_id
                      <> "] "
                      <> m.role
                      <> ": "
                      <> string.slice(m.content, 0, 120),
                    )
                  })
                }
              }
            }
            Error(err) -> io.println("Search error: " <> string.inspect(err))
          }
          repl_loop(state)
        }

        // ── /goal <prompt> ───────────────────────────────────────────────────
        _ if is_goal -> {
          let goal_prompt = string.trim(string.drop_start(trimmed, 6))
          let full_prompt = get_goal_prompt(goal_prompt)

          io.println("🚀 GOAL MODE: " <> goal_prompt)
          io.println(
            "Delegating goal to Babashka subagent. Telemetry will print in the background...",
          )

          let worker_id = "goal_worker_" <> state.session_id
          let datom =
            Datom(
              entity: worker_id,
              attribute: "spawn_worker",
              value: full_prompt,
            )
          let _ = state_actor.transact(state.db_conn, [datom], 1)

          repl_loop(state)
        }

        // ── /model <name> ────────────────────────────────────────────────────
        _ if is_model -> {
          let new_model = string.trim(string.drop_start(trimmed, 7))
          let _ =
            state_actor.create_session(
              state.db_conn,
              state.session_id,
              "repl",
              new_model,
              get_default_prompt(),
              int.to_float(system_time()) /. 1_000_000_000.0,
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
              get_tools_prompt(),
              90,
              option.None,
            )
          case new_agent_state {
            Ok(new_agent) ->
              repl_loop(
                REPLState(..state, model: new_model, agent_state: new_agent),
              )
            Error(_) -> repl_loop(REPLState(..state, model: new_model))
          }
        }

        // ── /cwd <path> ──────────────────────────────────────────────────────
        _ if is_cwd -> {
          let new_cwd = string.trim(string.drop_start(trimmed, 5))
          let new_exec_env =
            hermes_exec.TerminalEnv(..state.exec_env, cwd: new_cwd)
          let _ =
            state_actor.update_session_cwd(
              state.db_conn,
              state.session_id,
              new_cwd,
            )
          let new_agent_state =
            hermes_agent.AgentState(
              ..state.agent_state,
              cwd: new_cwd,
              exec_env: new_exec_env,
            )
          io.println("Switched directory to: " <> new_cwd)
          repl_loop(
            REPLState(
              ..state,
              cwd: new_cwd,
              exec_env: new_exec_env,
              agent_state: new_agent_state,
            ),
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
                state_actor.update_session_cwd(
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

        // ── /file <path> (Goal Mode Default) ──────────────────────────────────
        _ if is_file -> {
          let path = string.trim(string.drop_start(trimmed, 6))
          case simplifile.read(path) {
            Ok(content) -> {
              io.println("[Loaded prompt from file: " <> path <> "]")
              case state.api_key == "" {
                True -> {
                  let _response = run_mock_completion(content)
                  repl_loop(state)
                }
                False -> {
                  let full_prompt = get_goal_prompt(content)
                  io.println("🚀 GOAL MODE (Default - from file): " <> path)
                  io.println(
                    "Delegating goal to Babashka subagent. Telemetry will print in the background...",
                  )

                  let worker_id = "goal_worker_" <> state.session_id
                  let datom =
                    Datom(
                      entity: worker_id,
                      attribute: "spawn_worker",
                      value: full_prompt,
                    )
                  let _ = state_actor.transact(state.db_conn, [datom], 1)

                  repl_loop(state)
                }
              }
            }
            Error(err) -> {
              io.println("Error reading file: " <> string.inspect(err))
              repl_loop(state)
            }
          }
        }

        // ── LLM prompt via Goal Mode subagent (Default) ───────────────────────
        _ -> {
          case state.api_key == "" {
            True -> {
              let _response = run_mock_completion(trimmed)
              repl_loop(state)
            }
            False -> {
              let full_prompt = get_goal_prompt(trimmed)
              io.println("🚀 GOAL MODE (Default): " <> trimmed)
              io.println(
                "Delegating goal to Babashka subagent. Telemetry will print in the background...",
              )

              let worker_id = "goal_worker_" <> state.session_id
              let datom =
                Datom(
                  entity: worker_id,
                  attribute: "spawn_worker",
                  value: full_prompt,
                )
              let _ = state_actor.transact(state.db_conn, [datom], 1)

              repl_loop(state)
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

pub fn load_env_file() -> Nil {
  let path = constants.get_env_path()
  case simplifile.read(path) {
    Ok(content) -> {
      let lines = string.split(content, "\n")
      list.each(lines, fn(line) {
        let trimmed = string.trim(line)
        case trimmed == "" || string.starts_with(trimmed, "#") {
          True -> Nil
          False -> {
            case string.split_once(trimmed, "=") {
              Ok(#(key, val)) -> {
                let clean_key = string.trim(key)
                let clean_val = string.trim(val)
                let clean_val = case
                  string.starts_with(clean_val, "\"")
                  && string.ends_with(clean_val, "\"")
                {
                  True -> string.drop_start(clean_val, 1) |> string.drop_end(1)
                  False ->
                    case
                      string.starts_with(clean_val, "'")
                      && string.ends_with(clean_val, "'")
                    {
                      True ->
                        string.drop_start(clean_val, 1) |> string.drop_end(1)
                      False -> clean_val
                    }
                }
                constants.set_env(clean_key, clean_val)
              }
              Error(_) -> Nil
            }
          }
        }
      })
    }
    Error(_) -> Nil
  }
}

pub fn main() -> Nil {
  // Load environment variables from config
  load_env_file()

  case argv.load().arguments {
    ["--server"] -> {
      io.println("Server mode is disabled (website deleted).")
      Nil
    }
    ["--discord", token] -> {
      io.println("Starting Discord Gateway with token: " <> token)
      let assert Ok(_subj) = discord_gateway.start(token)
      // Keep main thread alive for the gateway
      sleep_ms(10_000_000)
    }
    ["--resume", session_id] -> {
      run_repl_resuming(session_id)
    }
    _ -> {
      run_repl()
    }
  }
}

/// Resume an existing session by ID — for crash recovery.
/// Boots the full REPL stack, then restores history + CWD from DB.
pub fn run_repl_resuming(target_session_id: String) -> Nil {
  io.println("══════════════════════════════════════════════════")
  io.println("  Hermes BEAM — Pure Gleam Agentic Runner v2.0.0")
  io.println("  🔄 RESUMING SESSION: " <> target_session_id)
  io.println("══════════════════════════════════════════════════")

  utils.set_expand_fun()

  let db_path = constants.path_join(constants.get_hermes_home(), "state.db")
  let assert Ok(conn) = hermes_state.connect(db_path)
  let assert Ok(Nil) = hermes_state.init_schema(conn)

  let temp_subj: process.Subject(SpawnedSubjects) = process.new_subject()
  let #(api_key, base_url) = resolve_api_credentials()
  let _ =
    process.spawn(fn() {
      let intent_subj = process.new_subject()
      let init_subj = process.new_subject()
      process.send(temp_subj, SpawnedSubjects(intent_subj, init_subj))
      let assert Ok(init_data) = process.receive(init_subj, 10_000)
      let selector =
        process.new_selector()
        |> process.select(intent_subj)
      intent_loop(
        selector,
        init_data.mcp_client_opt,
        init_data.supervisor_subj,
        api_key,
        base_url,
        init_data.agent_state,
      )
    })
  let assert Ok(spawned) = process.receive(temp_subj, 5000)
  let assert Ok(actor) = state_actor.start(conn, [spawned.intent_subj])

  let model = case constants.get_env("HERMES_MODEL") {
    Some(val) -> val
    None -> "meta-llama/llama-3-8b-instruct:free"
  }

  // Restore session history and CWD from DB
  let restored_history = case
    state_actor.get_session_history(actor, target_session_id)
  {
    Ok(msgs) -> msgs
    Error(_) -> []
  }
  let restored_cwd = case
    state_actor.get_session_cwd(actor, target_session_id)
  {
    Ok(cwd) if cwd != "" -> cwd
    _ -> hermes_exec.get_temp_dir()
  }

  let exec_env = hermes_exec.new_terminal_env(restored_cwd, 120_000, [])
  let exec_env = hermes_exec.init_session(exec_env)

  io.println("Session ID : " <> target_session_id <> " (resumed)")
  io.println("Database   : " <> db_path)
  io.println("Model      : " <> model)
  io.println(
    "Restored   : "
    <> int.to_string(list.length(restored_history))
    <> " messages from history",
  )
  io.println("CWD        : " <> restored_cwd)
  io.println("\nType /help to see commands. Press Ctrl+D or /quit to exit.")

  case
    hermes_agent.new_agent_state(
      target_session_id,
      model,
      restored_cwd,
      actor,
      exec_env,
      api_key,
      base_url,
      get_tools_prompt(),
      90,
      None,
    )
  {
    Error(err) -> io.println("Failed to initialise agent: " <> err)
    Ok(base_agent) -> {
      // Restore message history into agent state
      let resumed_agent =
        hermes_agent.AgentState(
          ..base_agent,
          history: list.reverse(restored_history),
        )

      let socket_path =
        constants.path_join(constants.get_hermes_home(), "subagents.sock")
      let assert Ok(supervisor_subj) =
        subagent_supervisor.start_supervisor(socket_path, actor)

      process.send(
        spawned.init_subj,
        IntentLoopInit(
          mcp_client_opt: None,
          supervisor_subj: supervisor_subj,
          agent_state: resumed_agent,
        ),
      )

      let state =
        REPLState(
          session_id: target_session_id,
          model: model,
          cwd: restored_cwd,
          db_conn: actor,
          exec_env: exec_env,
          api_key: api_key,
          base_url: base_url,
          agent_state: resumed_agent,
        )
      repl_loop(state)
    }
  }
}

pub fn run_repl() -> Nil {
  io.println("══════════════════════════════════════════════════")
  io.println("  Press Ctrl+C twice to exit. Type /help for commands.")
  io.println("══════════════════════════════════════════════════\n")

  utils.set_expand_fun()

  // 1. Initialize database
  let db_path = constants.path_join(constants.get_hermes_home(), "state.db")
  let assert Ok(conn) = hermes_state.connect(db_path)
  let assert Ok(Nil) = hermes_state.init_schema(conn)

  let temp_subj: process.Subject(SpawnedSubjects) = process.new_subject()
  let #(api_key, base_url) = resolve_api_credentials()
  let _ =
    process.spawn(fn() {
      let intent_subj = process.new_subject()
      let init_subj = process.new_subject()
      process.send(temp_subj, SpawnedSubjects(intent_subj, init_subj))
      let assert Ok(init_data) = process.receive(init_subj, 10_000)
      let selector =
        process.new_selector()
        |> process.select(intent_subj)
      intent_loop(
        selector,
        init_data.mcp_client_opt,
        init_data.supervisor_subj,
        api_key,
        base_url,
        init_data.agent_state,
      )
    })
  let assert Ok(spawned) = process.receive(temp_subj, 5000)

  let subjects = [spawned.intent_subj]

  let assert Ok(actor) = state_actor.start(conn, subjects)

  // 1b. Seed/persist local skills
  let routing_skill =
    Skill(
      name: "network-routing",
      description: "Calculates paths between network nodes",
      rules: [
        Rule(head: #("?x", "route/path", "?y"), body: [
          #("?x", "route/link", "?y"),
        ]),
        Rule(head: #("?x", "route/path", "?y"), body: [
          #("?x", "route/path", "?z"),
          #("?z", "route/link", "?y"),
        ]),
      ],
      facts: [
        Datom("A", "route/link", "B"),
        Datom("B", "route/link", "C"),
        Datom("C", "route/link", "D"),
      ],
    )

  let permission_skill =
    Skill(
      name: "user-permissions",
      description: "Calculates recursive group permission membership rules",
      rules: [
        Rule(head: #("?user", "user/member-of-recursive", "?group"), body: [
          #("?user", "user/member-of", "?group"),
        ]),
        Rule(head: #("?user", "user/member-of-recursive", "?group"), body: [
          #("?user", "user/member-of-recursive", "?subgroup"),
          #("?subgroup", "group/subgroup-of", "?group"),
        ]),
      ],
      facts: [
        Datom("alice", "user/member-of", "engineering"),
        Datom("bob", "user/member-of", "guests"),
        Datom("engineering", "group/subgroup-of", "admins"),
        Datom("admins", "permission/grant", "read:documents"),
        Datom("admins", "permission/grant", "write:documents"),
        Datom("engineering", "permission/grant", "read:code"),
        Datom("guests", "permission/grant", "read:public"),
      ],
    )

  let rule_datoms_1 =
    list.index_map(routing_skill.rules, fn(rule, idx) {
      let rule_name = "rule/" <> routing_skill.name <> "/" <> int.to_string(idx)
      evolutionary.rule_to_datoms(rule_name, rule)
    })
    |> list.flatten
  let datoms_1 = list.append(routing_skill.facts, rule_datoms_1)
  let assert Ok(Nil) = state_actor.transact(actor, datoms_1, 1)

  let rule_datoms_2 =
    list.index_map(permission_skill.rules, fn(rule, idx) {
      let rule_name =
        "rule/" <> permission_skill.name <> "/" <> int.to_string(idx)
      evolutionary.rule_to_datoms(rule_name, rule)
    })
    |> list.flatten
  let datoms_2 = list.append(permission_skill.facts, rule_datoms_2)
  let assert Ok(Nil) = state_actor.transact(actor, datoms_2, 1)

  // 1c. Load skills dynamically from hermes_home / skills/
  let skills_dir = constants.path_join(constants.get_hermes_home(), "skills")
  case skill_compiler.load_skills_from_dir(skills_dir) {
    Ok(compiled_skills) -> {
      list.each(compiled_skills, fn(sk) {
        let rule_datoms =
          list.index_map(sk.rules, fn(rule, idx) {
            let rule_name = "rule/" <> sk.name <> "/" <> int.to_string(idx)
            evolutionary.rule_to_datoms(rule_name, rule)
          })
          |> list.flatten
        let datoms = list.append(sk.facts, rule_datoms)
        let _ = state_actor.transact(actor, datoms, 1)
        io.println("Loaded skill: " <> sk.name)
      })
    }
    Error(_) -> Nil
  }

  // 2. Load credentials
  let model = case constants.get_env("HERMES_MODEL") {
    Some(val) -> val
    None -> "meta-llama/llama-3-8b-instruct:free"
  }

  // Start MCP Client if HERMES_MCP_CMD is set
  let mcp_client_opt = case constants.get_env("HERMES_MCP_CMD") {
    Some(cmd) -> {
      let temp_mcp_subj: process.Subject(
        process.Subject(mcp_client.JsonRpcNotification),
      ) = process.new_subject()
      let _ =
        process.spawn(fn() {
          let notif_subj = process.new_subject()
          process.send(temp_mcp_subj, notif_subj)
          let selector =
            process.new_selector()
            |> process.select(notif_subj)
          notification_loop(selector, actor)
        })
      let assert Ok(notif_subj) = process.receive(temp_mcp_subj, 5000)

      case mcp_client.start(cmd, Some(notif_subj)) {
        Ok(client) -> {
          let _ = mcp_client.initialize(client)
          io.println("MCP Client started.")
          Some(client)
        }
        Error(e) -> {
          io.println("Failed to start MCP client: " <> e)
          None
        }
      }
    }
    None -> None
  }

  let socket_path =
    constants.path_join(constants.get_hermes_home(), "subagents.sock")
  let assert Ok(supervisor_subj) =
    subagent_supervisor.start_supervisor(socket_path, actor)

  // 3. Create session
  let session_id = hermes_exec.generate_uuid()
  let assert Ok(Nil) =
    state_actor.create_session(
      actor,
      session_id,
      "repl",
      model,
      get_tools_prompt(),
      int.to_float(system_time()) /. 1_000_000_000.0,
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
      actor,
      exec_env,
      api_key,
      base_url,
      get_tools_prompt(),
      90,
      mcp_client_opt,
    )

  case agent_result {
    Error(err) -> {
      io.println("Failed to initialise agent: " <> err)
      Nil
    }
    Ok(agent_state) -> {
      process.send(
        spawned.init_subj,
        IntentLoopInit(mcp_client_opt, supervisor_subj, agent_state),
      )

      let state =
        REPLState(
          session_id: session_id,
          model: model,
          cwd: exec_env.cwd,
          db_conn: actor,
          exec_env: exec_env,
          api_key: api_key,
          base_url: base_url,
          agent_state: agent_state,
        )

      repl_loop(state)
    }
  }
}

fn notification_loop(
  selector: process.Selector(mcp_client.JsonRpcNotification),
  actor: state_actor.StateActor,
) -> Nil {
  case process.selector_receive(selector, 600_000) {
    Ok(notif) -> {
      let params_str = case notif.params {
        Some(p) -> string.inspect(p)
        None -> "{}"
      }
      let _ =
        state_actor.handle_mcp_notification(actor, notif.method, params_str)
      notification_loop(selector, actor)
    }
    Error(_) -> notification_loop(selector, actor)
  }
}

pub type ToolCallRequest {
  ToolCallRequest(id: Int, name: String, arguments: String)
}

pub fn decode_tool_call_request(
  json_str: String,
) -> Result(ToolCallRequest, String) {
  let decoder = {
    use id <- decode.field("id", decode.int)
    use params <- decode.field("params", {
      use name <- decode.field("name", decode.string)
      use arguments <- decode.field("arguments", decode.string)
      decode.success(#(name, arguments))
    })
    decode.success(ToolCallRequest(id: id, name: params.0, arguments: params.1))
  }
  case json.parse(from: json_str, using: decoder) {
    Ok(req) -> Ok(req)
    Error(_) -> Error("Invalid tool call request payload")
  }
}

fn intent_loop(
  selector: process.Selector(Datom),
  mcp_client_opt: option.Option(mcp_client.McpClient),
  supervisor_subj: process.Subject(subagent_supervisor.SupervisorMessage),
  api_key: String,
  base_url: String,
  agent_state: hermes_agent.AgentState,
) -> Nil {
  case process.selector_receive(selector, 600_000) {
    Ok(datom) -> {
      case datom.attribute {
        "call_tool" -> {
          let msg =
            "[Side Effect] Reactive Datalog intent to call tool: "
            <> datom.value
          io.println(msg)
          log_event(msg)
          case mcp_client_opt {
            option.Some(client) -> {
              let _ = mcp_client.call_tool(client, "reactive_task", datom.value)
              Nil
            }
            option.None -> Nil
          }
          intent_loop(
            selector,
            mcp_client_opt,
            supervisor_subj,
            api_key,
            base_url,
            agent_state,
          )
        }
        "spawn_worker" -> {
          let msg = "[Side Effect] Spawning subagent worker: " <> datom.entity
          io.println(msg)
          log_event(msg)
          let tools = hermes_agent.all_tool_schemas(mcp_client_opt)
          process.send(
            supervisor_subj,
            subagent_supervisor.StartSubagent(
              datom.entity,
              datom.value,
              api_key,
              base_url,
              tools,
            ),
          )
          intent_loop(
            selector,
            mcp_client_opt,
            supervisor_subj,
            api_key,
            base_url,
            agent_state,
          )
        }
        "llm_request" -> {
          let msg =
            "[Side Effect] Sending LLM request to babashka worker: "
            <> datom.entity
          io.println(msg)
          log_event(msg)
          let msg_str =
            "{\"jsonrpc\":\"2.0\",\"method\":\"execute_task\",\"params\":"
            <> datom.value
            <> "}"
          process.send(
            supervisor_subj,
            subagent_supervisor.SendSubagentMsg(datom.entity, msg_str),
          )
          intent_loop(
            selector,
            mcp_client_opt,
            supervisor_subj,
            api_key,
            base_url,
            agent_state,
          )
        }
        "telemetry" -> {
          let msg = "\n[Babashka Telemetry] " <> datom.value
          io.println(msg)
          log_event(msg)
          intent_loop(
            selector,
            mcp_client_opt,
            supervisor_subj,
            api_key,
            base_url,
            agent_state,
          )
        }
        "call_tool_request" -> {
          let msg =
            "[Side Effect] Subagent requested tool execution: " <> datom.value
          io.println(msg)
          log_event(msg)
          case decode_tool_call_request(datom.value) {
            Ok(req) -> {
              let call =
                hermes_agent.ToolCall(
                  id: int.to_string(req.id),
                  name: req.name,
                  arguments: req.arguments,
                )
              // Execute tool on Gleam side!
              let #(next_env, result) =
                hermes_agent.dispatch_tool(agent_state, call, False)

              // Build JSON-RPC response
              let response_payload =
                "{\"jsonrpc\":\"2.0\",\"id\":"
                <> int.to_string(req.id)
                <> ",\"result\":"
                <> result
                <> "}\n"

              // Forward response back to the supervisor to send to the worker socket
              process.send(
                supervisor_subj,
                subagent_supervisor.SendSubagentMsg(
                  datom.entity,
                  response_payload,
                ),
              )

              // Recurse with updated exec_env in agent_state
              let next_agent_state =
                hermes_agent.AgentState(
                  ..agent_state,
                  exec_env: next_env,
                  cwd: next_env.cwd,
                )
              intent_loop(
                selector,
                mcp_client_opt,
                supervisor_subj,
                api_key,
                base_url,
                next_agent_state,
              )
            }
            Error(e) -> {
              io.println("Error decoding tool request: " <> e)
              intent_loop(
                selector,
                mcp_client_opt,
                supervisor_subj,
                api_key,
                base_url,
                agent_state,
              )
            }
          }
        }
        _ ->
          intent_loop(
            selector,
            mcp_client_opt,
            supervisor_subj,
            api_key,
            base_url,
            agent_state,
          )
      }
    }
    Error(_) ->
      intent_loop(
        selector,
        mcp_client_opt,
        supervisor_subj,
        api_key,
        base_url,
        agent_state,
      )
  }
}
