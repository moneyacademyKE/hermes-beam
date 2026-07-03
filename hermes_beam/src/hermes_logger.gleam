import constants
import gleam/json
import gleam/list
import simplifile
import glogg/logger

@external(erlang, "erlang", "system_time")
fn system_time() -> Int

pub fn log(level_str: String, session_id: String, msg: String) -> Nil {
  log_fields(level_str, session_id, msg, [])
}

pub fn event_message(event: String, fields: List(#(String, String))) -> String {
  let details =
    list.map(fields, fn(field) {
      let #(key, value) = field
      key <> "=" <> value
    })
    |> string_join(" ")

  case details {
    "" -> "event=" <> event
    _ -> "event=" <> event <> " " <> details
  }
}

pub fn event(
  level_str: String,
  session_id: String,
  event_name: String,
  fields: List(#(String, String)),
) -> Nil {
  log_fields(level_str, session_id, event_message(event_name, fields), [
    #("event", event_name),
    ..fields
  ])
}

pub fn failure(
  session_id: String,
  event_name: String,
  reason: String,
  fields: List(#(String, String)),
) -> Nil {
  event("ERROR", session_id, event_name, [#("reason", reason), ..fields])
}

fn log_fields(
  level_str: String,
  session_id: String,
  msg: String,
  fields: List(#(String, String)),
) -> Nil {
  let ts = system_time()

  let metadata =
    list.map(fields, fn(field) {
      let #(key, value) = field
      #(key, json.string(value))
    })

  let json_obj =
    json.object([
      #("timestamp", json.int(ts)),
      #("level", json.string(level_str)),
      #("session_id", json.string(session_id)),
      #("message", json.string(msg)),
      #("metadata", json.object(metadata)),
    ])
  let line = json.to_string(json_obj) <> "\n"

  let _ = constants.prepare_runtime_dirs()
  let log_dir = constants.get_logs_dir()
  let _ = simplifile.create_directory_all(log_dir)
  let log_file = log_dir <> "/agent.jsonl"
  let _ = simplifile.append(to: log_file, contents: line)

  let app_logger = logger.new("hermes")
  let logger_fields = [logger.string("session_id", session_id)]

  case level_str {
    "DEBUG" -> logger.debug(app_logger, msg, logger_fields)
    "INFO" -> logger.info(app_logger, msg, logger_fields)
    "WARNING" -> logger.warning(app_logger, msg, logger_fields)
    "ERROR" -> logger.error(app_logger, msg, logger_fields)
    _ -> logger.info(app_logger, msg, logger_fields)
  }

  Nil
}

fn string_join(parts: List(String), separator: String) -> String {
  case parts {
    [] -> ""
    [first, ..rest] -> string_join_loop(rest, separator, first)
  }
}

fn string_join_loop(parts: List(String), separator: String, acc: String) -> String {
  case parts {
    [] -> acc
    [next, ..rest] -> string_join_loop(rest, separator, acc <> separator <> next)
  }
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
