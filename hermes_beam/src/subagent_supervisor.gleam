import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleamdb.{type Datom}
import uds_ffi
import gleam/io
import gleam/string
import gleam/bit_array
import gleam/list
import hermes_exec

pub type SupervisorMessage {
  StartSubagent(id: String, path: String)
  SendSubagentMsg(id: String, msg: String)
  BroadcastState(datom: Datom)
  AcceptConnection(sock: uds_ffi.Socket)
  SubagentMsg(sock: uds_ffi.Socket, msg: String)
  SubagentDisconnect(sock: uds_ffi.Socket)
}

pub type SupervisorState {
  SupervisorState(
    socket_path: String,
    listen_sock: uds_ffi.ListenSocket,
    active_workers: List(#(String, uds_ffi.Socket)),
    datom_subj: Subject(Datom)
  )
}

pub fn start_supervisor(socket_path: String, datom_subj: Subject(Datom)) -> Result(Subject(SupervisorMessage), String) {
  case uds_ffi.listen_uds(socket_path) {
    Ok(lsock) -> {
      let state = SupervisorState(socket_path, lsock, [], datom_subj)
      
      let res = actor.new(state)
      |> actor.on_message(handle_message)
      |> actor.start()

      case res {
        Ok(started) -> {
          let subj = started.data
          // Spawn listener using the actor's subject
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
    StartSubagent(id, path) -> {
      io.println("Supervisor starting subagent: " <> id <> " with path " <> path)
      let cmd = "cd /Users/moe/Desktop/ayncoder/babashka_workers && bb -m worker " <> state.socket_path
      let _ = hermes_exec.spawn_port(cmd)
      actor.continue(state)
    }
    SendSubagentMsg(id, payload) -> {
      let _ = list_find_and_send(state.active_workers, id, payload)
      actor.continue(state)
    }
    BroadcastState(datom) -> {
      io.println("Supervisor broadcasting datom: " <> datom.attribute)
      actor.continue(state)
    }
    AcceptConnection(_sock) -> {
      io.println("Actor registered new subagent socket")
      // We don't have state.self, but worker_read_loop needs the Subject.
      // Wait, we need the Subject here to pass to worker_read_loop!
      // But we can't easily get it inside handle_message unless we store it.
      actor.continue(state) // WAIT! This won't work, worker_read_loop won't spawn!
    }
    SubagentMsg(_sock, msg) -> {
      io.println("Actor received subagent msg: " <> msg)
      let datom = gleamdb.Datom(entity: "worker", attribute: "telemetry", value: msg)
      process.send(state.datom_subj, datom)
      actor.continue(state)
    }
    SubagentDisconnect(sock) -> {
      io.println("Actor handling disconnect")
      let next_workers = list.filter(state.active_workers, fn(w) { w.1 != sock })
      actor.continue(SupervisorState(..state, active_workers: next_workers))
    }
  }
}

fn accept_loop(lsock: uds_ffi.ListenSocket, subj: Subject(SupervisorMessage)) -> Nil {
  case uds_ffi.accept_uds(lsock) {
    Ok(sock) -> {
      io.println("Accepted new UDS connection")
      // Spawn receiver process for this socket right here where we HAVE the subject!
      let _ = process.spawn(fn() {
        worker_read_loop(sock, subj)
      })
      process.send(subj, AcceptConnection(sock))
      accept_loop(lsock, subj)
    }
    Error(e) -> {
      io.println("Accept loop failed: " <> string.inspect(e) <> ". Auto-healing in 1s...")
      process.sleep(1000)
      accept_loop(lsock, subj)
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
