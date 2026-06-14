import constants
import gleam/json
import simplifile
import glogg/logger

@external(erlang, "erlang", "system_time")
fn system_time() -> Int

pub fn log(level_str: String, session_id: String, msg: String) -> Nil {
  let ts = system_time()

  let json_obj =
    json.object([
      #("timestamp", json.int(ts)),
      #("level", json.string(level_str)),
      #("session_id", json.string(session_id)),
      #("message", json.string(msg)),
    ])
  let line = json.to_string(json_obj) <> "\n"

  let log_dir = constants.get_hermes_home() <> "/logs"
  let _ = simplifile.create_directory_all(log_dir)
  let log_file = log_dir <> "/agent.jsonl"
  let _ = simplifile.append(to: log_file, contents: line)

  let app_logger = logger.new("hermes")
  let fields = [logger.string("session_id", session_id)]

  case level_str {
    "DEBUG" -> logger.debug(app_logger, msg, fields)
    "INFO" -> logger.info(app_logger, msg, fields)
    "WARNING" -> logger.warning(app_logger, msg, fields)
    "ERROR" -> logger.error(app_logger, msg, fields)
    _ -> logger.info(app_logger, msg, fields)
  }

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
