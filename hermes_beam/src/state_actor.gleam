import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleamdb.{type Database, type Datom}
import gleam/option.{type Option, Some, None}
import gleam/list
import hermes_state
import sqlight

pub type Message {
  TransactDatoms(
    datoms: List(Datom),
    tx: Int,
    reply_to: Subject(Result(Nil, sqlight.Error)),
  )
  LoadDatabase(reply_to: Subject(Result(Database, sqlight.Error)))
  Close(reply_to: Subject(Result(Nil, sqlight.Error)))
  CreateSession(
    id: String,
    source: String,
    model: String,
    system_prompt: String,
    started_at: Float,
    reply_to: Subject(Result(Nil, sqlight.Error)),
  )
  EndSession(
    id: String,
    end_reason: String,
    ended_at: Float,
    reply_to: Subject(Result(Nil, sqlight.Error)),
  )
  UpdateSessionCwd(
    id: String,
    cwd: String,
    reply_to: Subject(Result(Nil, sqlight.Error)),
  )
  InsertMessage(
    session_id: String,
    role: String,
    content: String,
    timestamp: Float,
    reply_to: Subject(Result(Nil, sqlight.Error)),
  )
  ListSessions(reply_to: Subject(Result(List(String), sqlight.Error)))
  GetSessionCwd(
    id: String,
    reply_to: Subject(Result(String, sqlight.Error)),
  )
  HandleMcpNotification(
    method: String,
    params: String,
    reply_to: Subject(Result(Nil, sqlight.Error)),
  )
}

pub type ActorState {
  ActorState(
    conn: sqlight.Connection,
    broadcast: Option(Subject(Datom))
  )
}

pub opaque type StateActor {
  StateActor(subject: Subject(Message))
}

pub fn start(
  conn: sqlight.Connection,
  broadcast: Option(Subject(Datom))
) -> Result(StateActor, actor.StartError) {
  // Ensure datoms schema is initialized
  let _ =
    sqlight.exec(
      "
      CREATE TABLE IF NOT EXISTS datoms (
          entity TEXT NOT NULL,
          attribute TEXT NOT NULL,
          value TEXT NOT NULL,
          tx INTEGER NOT NULL,
          PRIMARY KEY (entity, attribute, value, tx)
      );
    ",
      conn,
    )

  actor.new(ActorState(conn, broadcast))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { StateActor(started.data) })
}

fn handle_message(
  state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
    case message {
    TransactDatoms(datoms, tx, reply_to) -> {
      let res = hermes_state.save_datoms(state.conn, datoms, tx)
      case state.broadcast {
        Some(subj) -> list.each(datoms, process.send(subj, _))
        None -> Nil
      }
      process.send(reply_to, res)
      actor.continue(state)
    }
    LoadDatabase(reply_to) -> {
      let res = hermes_state.load_database(state.conn)
      process.send(reply_to, res)
      actor.continue(state)
    }
    Close(reply_to) -> {
      let res = sqlight.close(state.conn)
      process.send(reply_to, res)
      actor.stop()
    }
    HandleMcpNotification(method, params, reply_to) -> {
      let datoms = [gleamdb.Datom(entity: "mcp_client", attribute: method, value: params)]
      let res = hermes_state.save_datoms(state.conn, datoms, 0)
      case state.broadcast {
        Some(subj) -> list.each(datoms, process.send(subj, _))
        None -> Nil
      }
      process.send(reply_to, res)
      actor.continue(state)
    }
    CreateSession(id, source, model, system_prompt, started_at, reply_to) -> {
      let res =
        hermes_state.create_session(
          state.conn,
          id,
          source,
          model,
          system_prompt,
          started_at,
        )
      process.send(reply_to, res)
      actor.continue(state)
    }
    EndSession(id, end_reason, ended_at, reply_to) -> {
      let res =
        hermes_state.end_session(state.conn, id, end_reason, ended_at)
      process.send(reply_to, res)
      actor.continue(state)
    }
    UpdateSessionCwd(id, cwd, reply_to) -> {
      let res = hermes_state.update_session_cwd(state.conn, id, cwd)
      process.send(reply_to, res)
      actor.continue(state)
    }
    InsertMessage(session_id, role, content, timestamp, reply_to) -> {
      let res =
        hermes_state.insert_message(
          state.conn,
          session_id,
          role,
          content,
          timestamp,
        )
      process.send(reply_to, res)
      actor.continue(state)
    }
    ListSessions(reply_to) -> {
      let res = hermes_state.list_sessions(state.conn)
      process.send(reply_to, res)
      actor.continue(state)
    }
    GetSessionCwd(id, reply_to) -> {
      let res = hermes_state.get_session_cwd(state.conn, id)
      process.send(reply_to, res)
      actor.continue(state)
    }
  }
}

pub fn transact(
  actor: StateActor,
  datoms: List(Datom),
  tx: Int,
) -> Result(Nil, sqlight.Error) {
  actor.call(actor.subject, 5000, TransactDatoms(datoms, tx, _))
}

pub fn load(actor: StateActor) -> Result(Database, sqlight.Error) {
  actor.call(actor.subject, 5000, LoadDatabase)
}

pub fn close(actor: StateActor) -> Result(Nil, sqlight.Error) {
  actor.call(actor.subject, 5000, Close)
}

pub fn create_session(
  actor: StateActor,
  id: String,
  source: String,
  model: String,
  system_prompt: String,
  started_at: Float,
) -> Result(Nil, sqlight.Error) {
  actor.call(
    actor.subject,
    5000,
    CreateSession(id, source, model, system_prompt, started_at, _),
  )
}

pub fn end_session(
  actor: StateActor,
  id: String,
  end_reason: String,
  ended_at: Float,
) -> Result(Nil, sqlight.Error) {
  actor.call(actor.subject, 5000, EndSession(id, end_reason, ended_at, _))
}

pub fn update_session_cwd(
  actor: StateActor,
  id: String,
  cwd: String,
) -> Result(Nil, sqlight.Error) {
  actor.call(actor.subject, 5000, UpdateSessionCwd(id, cwd, _))
}

pub fn insert_message(
  actor: StateActor,
  session_id: String,
  role: String,
  content: String,
  timestamp: Float,
) -> Result(Nil, sqlight.Error) {
  actor.call(
    actor.subject,
    5000,
    InsertMessage(session_id, role, content, timestamp, _),
  )
}

pub fn list_sessions(actor: StateActor) -> Result(List(String), sqlight.Error) {
  actor.call(actor.subject, 5000, ListSessions)
}

pub fn get_session_cwd(
  actor: StateActor,
  id: String,
) -> Result(String, sqlight.Error) {
  actor.call(actor.subject, 1000, fn(subject) { GetSessionCwd(id, subject) })
}

pub fn handle_mcp_notification(
  actor: StateActor,
  method: String,
  params: String,
) -> Result(Nil, sqlight.Error) {
  actor.call(actor.subject, 1000, fn(subject) { HandleMcpNotification(method, params, subject) })
}
