import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleamdb.{type Datom}
import uds_ffi
import gleam/io
import gleam/string
import gleam/bit_array
import gleam/list
import gleam/json
import hermes_exec
import state_actor.{type StateActor}

pub type SupervisorMessage {
  /// Spawns a new subagent process with the given ID and initial system prompt/instructions.
  StartSubagent(id: String, prompt: String, api_key: String, base_url: String, tools_json: String)
  /// Sends a message string to an active subagent via its mailbox.
  SendSubagentMsg(id: String, msg: String)
  /// Broadcasts a Datom globally.
  BroadcastState(datom: Datom)
  /// Notification that a worker has finished its task.
  WorkerDone(id: String)
  
  AcceptConnection(sock: uds_ffi.Socket)
  SubagentMsg(sock: uds_ffi.Socket, msg: String)
  SubagentDisconnect(sock: uds_ffi.Socket)
}

pub type SupervisorState {
  SupervisorState(
    socket_path: String,
    listen_sock: uds_ffi.ListenSocket,
    active_workers: List(#(String, uds_ffi.Socket)),
    db_conn: StateActor,
    self: Subject(SupervisorMessage),
    max_workers: Int,
    pending_queue: List(#(String, String, String, String, String))
  )
}

/// Start the OTP supervisor process managing subagents.
pub fn start_supervisor(socket_path: String, db_conn: StateActor) -> Result(Subject(SupervisorMessage), String) {
  case uds_ffi.listen_uds(socket_path) {
    Ok(lsock) -> {
      let res = actor.new_with_initialiser(1000, fn(subj) {
        let state = SupervisorState(socket_path, lsock, [], db_conn, subj, 5, [])
        let selector = process.new_selector() |> process.select(subj)
        actor.initialised(state)
        |> actor.selecting(selector)
        |> actor.returning(subj)
        |> Ok
      })
      |> actor.on_message(handle_message)
      |> actor.start()

      case res {
        Ok(started) -> {
          let subj = started.data
          let _ = process.spawn(fn() {
            accept_loop(lsock, subj)
          })
          Ok(subj)
        }
        Error(e) -> Error("Actor start failed: " <> string.inspect(e))
      }
    }
    Error(e) -> Error("Failed to start UDS supervisor: " <> string.inspect(e))
  }
}

fn handle_message(state: SupervisorState, msg: SupervisorMessage) -> actor.Next(SupervisorState, SupervisorMessage) {
  case msg {
    StartSubagent(id, prompt, api_key, base_url, tools_json) -> {
      case list.length(state.active_workers) < state.max_workers {
        True -> {
          io.println("Supervisor starting subagent Babashka process: " <> id)
          
          let cmd = "cd /Users/moe/Desktop/ayncoder/babashka_workers && bb -m worker " <> state.socket_path
          let _ = hermes_exec.spawn_port(cmd)
          
          let new_queue = list.append(state.pending_queue, [#(id, prompt, api_key, base_url, tools_json)])
          actor.continue(SupervisorState(..state, pending_queue: new_queue))
        }
        False -> {
          io.println("Supervisor queueing subagent task: " <> id)
          let new_queue = list.append(state.pending_queue, [#(id, prompt, api_key, base_url, tools_json)])
          actor.continue(SupervisorState(..state, pending_queue: new_queue))
        }
      }
    }
    WorkerDone(id) -> {
      io.println("Supervisor detected worker completion: " <> id)
      // Remove from active_workers
      let next_workers = list.filter(state.active_workers, fn(w) { w.0 != id })
      actor.continue(SupervisorState(..state, active_workers: next_workers))
    }
    SendSubagentMsg(id, payload) -> {
      let _ = list_find_and_send(state.active_workers, id, payload)
      actor.continue(state)
    }
    BroadcastState(datom) -> {
      io.println("Supervisor broadcasting datom: " <> datom.attribute)
      actor.continue(state)
    }
    AcceptConnection(sock) -> {
      io.println("Actor registered new subagent socket")
      let _ = process.spawn(fn() {
        worker_read_loop(sock, state.self)
      })
      
      // When a new socket connects, we pair it with the first pending task in the queue.
      case state.pending_queue {
        [] -> {
          io.println("No pending tasks for new connection.")
          actor.continue(state)
        }
        [#(id, prompt, api_key, base_url, tools_json), ..rest] -> {
          let next_workers = [#(id, sock), ..state.active_workers]
          
          let datoms = case state_actor.get_all_datoms(state.db_conn) {
            Ok(ds) -> ds
            Error(_) -> []
          }

          let datoms_json = {
            json.array(datoms, of: fn(d) {
              json.object([
                #("entity", json.string(d.entity)),
                #("attribute", json.string(d.attribute)),
                #("value", json.string(d.value)),
              ])
            })
            |> json.to_string
          }

          // Build JSON-RPC payload
          let payload = "{\"jsonrpc\":\"2.0\",\"method\":\"execute_task\",\"params\":{\"url\":\"" <> base_url <> "\",\"model\":\"gpt-4o-mini\",\"api_key\":\"" <> api_key <> "\",\"messages\":[{\"role\":\"user\",\"content\":\"" <> string.replace(prompt, "\"", "\\\"") <> "\"}],\"tools\":" <> tools_json <> ",\"datoms\":" <> datoms_json <> "}}"
          
          let _ = uds_ffi.send_uds(sock, bit_array.from_string(payload))
          actor.continue(SupervisorState(..state, active_workers: next_workers, pending_queue: rest))
        }
      }
    }
    SubagentMsg(sock, msg) -> {
      io.println("Actor received subagent msg: " <> msg)
      
      let worker_id = case list.find(state.active_workers, fn(w) { w.1 == sock }) {
        Ok(#(id, _)) -> id
        Error(_) -> "unknown_worker"
      }
      
      // Check if it's a delegated tool call request from the subagent
      let is_tool_call = string.contains(msg, "\"call_tool_on_gleam\"")
      case is_tool_call {
        True -> {
          let datom = gleamdb.Datom(entity: worker_id, attribute: "call_tool_request", value: msg)
          let _ = state_actor.transact(state.db_conn, [datom], 1)
          Nil
        }
        False -> {
          let datom = gleamdb.Datom(entity: worker_id, attribute: "telemetry", value: msg)
          let _ = state_actor.transact(state.db_conn, [datom], 1)
          Nil
        }
      }
      
      let should_close = string.contains(msg, "task_result") || string.contains(msg, "\"error\"")
      case should_close {
        True -> {
          let _ = uds_ffi.close_uds(sock)
          Nil
        }
        False -> Nil
      }
      
      actor.continue(state)
    }
    SubagentDisconnect(sock) -> {
      io.println("Actor handling disconnect")
      // Find which ID this was to print
      case list.find(state.active_workers, fn(w) { w.1 == sock }) {
        Ok(#(id, _)) -> {
          actor.send(state.self, WorkerDone(id))
          // Also if we have pending tasks and we are below capacity, start a new bb worker
          case list.length(state.active_workers) - 1 < state.max_workers {
            True -> {
              case state.pending_queue {
                [] -> Nil
                _ -> {
                  let cmd = "cd /Users/moe/Desktop/ayncoder/babashka_workers && bb -m worker " <> state.socket_path
                  let _ = hermes_exec.spawn_port(cmd)
                  Nil
                }
              }
            }
            False -> Nil
          }
        }
        Error(_) -> Nil
      }
      
      let next_workers = list.filter(state.active_workers, fn(w) { w.1 != sock })
      actor.continue(SupervisorState(..state, active_workers: next_workers))
    }
  }
}

fn accept_loop(lsock: uds_ffi.ListenSocket, subj: Subject(SupervisorMessage)) -> Nil {
  case uds_ffi.accept_uds(lsock) {
    Ok(sock) -> {
      io.println("Accepted new UDS connection")
      process.send(subj, AcceptConnection(sock))
      accept_loop(lsock, subj)
    }
    Error(e) -> {
      io.println("Accept loop failed: " <> string.inspect(e))
    }
  }
}

fn worker_read_loop(sock: uds_ffi.Socket, subj: Subject(SupervisorMessage)) -> Nil {
  case uds_ffi.recv_uds(sock, 0) {
    Ok(data) -> {
      case bit_array.to_string(data) {
        Ok(s) -> process.send(subj, SubagentMsg(sock, s))
        Error(_) -> Nil
      }
      worker_read_loop(sock, subj)
    }
    Error(_) -> {
      process.send(subj, SubagentDisconnect(sock))
      let _ = uds_ffi.close_uds(sock)
      Nil
    }
  }
}

fn list_find_and_send(workers: List(#(String, uds_ffi.Socket)), target_id: String, msg: String) -> Nil {
  case workers {
    [] -> Nil
    [#(id, sock), ..rest] -> {
      case id == target_id {
        True -> {
          let _ = uds_ffi.send_uds(sock, bit_array.from_string(msg))
          Nil
        }
        False -> list_find_and_send(rest, target_id, msg)
      }
    }
  }
}
