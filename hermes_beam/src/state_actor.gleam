import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleamdb.{type Database, type Datom}
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
}

pub type ActorState {
  ActorState(conn: sqlight.Connection)
}

pub opaque type StateActor {
  StateActor(subject: Subject(Message))
}

pub fn start(conn: sqlight.Connection) -> Result(StateActor, actor.StartError) {
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

  actor.new(ActorState(conn))
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
