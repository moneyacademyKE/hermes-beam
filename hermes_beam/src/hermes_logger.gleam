import constants
import gleam/io
import gleam/json
import simplifile

@external(erlang, "erlang", "system_time")
fn system_time() -> Int

pub fn log(level: String, session_id: String, msg: String) -> Nil {
  let ts = system_time()

  let json_obj =
    json.object([
      #("timestamp", json.int(ts)),
      #("level", json.string(level)),
      #("session_id", json.string(session_id)),
      #("message", json.string(msg)),
    ])
  let line = json.to_string(json_obj) <> "\n"

  case level {
    "ERROR" -> io.println(line)
    _ -> Nil
  }

  let log_dir = constants.get_hermes_home() <> "/logs"
  let _ = simplifile.create_directory_all(log_dir)
  let log_file = log_dir <> "/agent.jsonl"

  let _ = simplifile.append(to: log_file, contents: line)
  Nil
}

pub fn info(session_id: String, msg: String) -> Nil {
  log("INFO", session_id, msg)
}

pub fn error(session_id: String, msg: String) -> Nil {
  log("ERROR", session_id, msg)
}

pub fn debug(session_id: String, msg: String) -> Nil {
  log("DEBUG", session_id, msg)
}
