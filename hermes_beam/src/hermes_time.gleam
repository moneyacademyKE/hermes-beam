import gleam/io
import gleam/string
import gleam/int
import gleam/list
import gleam/option.{type Option, Some, None}
import gleam/result
import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor
import gleam/dynamic.{type Dynamic}
import simplifile

pub type OsFamily {
  Darwin
  Linux
  WindowsNt
  Other
}

pub type DateTime {
  DateTime(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    second: Int,
    offset_seconds: Int,
    timezone_name: String,
  )
}

pub type Message {
  GetTimezone(reply_to: Subject(Option(String)))
  ResetCache
}

pub type CacheState {
  CacheState(
    resolved: Bool,
    timezone_name: Option(String),
  )
}

pub type ErlangDateTime =
  #(#(Int, Int, Int), #(Int, Int, Int))

@external(erlang, "calendar", "local_time")
pub fn erl_local_time() -> ErlangDateTime

@external(erlang, "calendar", "universal_time")
pub fn erl_universal_time() -> ErlangDateTime

@external(erlang, "calendar", "datetime_to_gregorian_seconds")
pub fn erl_datetime_to_gregorian_seconds(dt: ErlangDateTime) -> Int

@external(erlang, "hermes_time_ffi", "os_cmd")
pub fn run_command(command: String) -> String

@external(erlang, "hermes_time_ffi", "read_link")
pub fn read_link(path: String) -> Result(String, Nil)

@external(erlang, "hermes_time_ffi", "whereis_cache")
fn whereis_cache() -> Result(Pid, Nil)

@external(erlang, "hermes_time_ffi", "register_cache")
fn register_cache(pid: Pid) -> Result(Nil, Nil)

@external(erlang, "hermes_time_ffi", "send_to_cache_pid")
fn send_to_cache_pid(pid: Pid, msg: Message) -> Nil

@external(erlang, "hermes_time_ffi", "get_env")
pub fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "hermes_time_ffi", "os_family")
pub fn os_family() -> OsFamily

pub fn get_hermes_home() -> String {
  case get_env("HERMES_HOME") {
    Ok(val) -> val
    Error(_) -> {
      case os_family() {
        WindowsNt -> {
          case get_env("LOCALAPPDATA") {
            Ok(local) -> local <> "/hermes"
            Error(_) -> {
              case get_env("USERPROFILE") {
                Ok(profile) -> profile <> "/AppData/Local/hermes"
                Error(_) -> "C:/Users/Default/AppData/Local/hermes"
              }
            }
          }
        }
        _ -> {
          case get_env("HOME") {
            Ok(home) -> home <> "/.hermes"
            Error(_) -> "/root/.hermes"
          }
        }
      }
    }
  }
}

pub fn get_config_path() -> String {
  get_hermes_home() <> "/config.yaml"
}

pub fn parse_timezone_from_yaml(content: String) -> Result(String, Nil) {
  let lines = string.split(content, on: "\n")
  case list.find_map(lines, extract_timezone_line) {
    Ok(tz) -> Ok(tz)
    Error(_) -> Error(Nil)
  }
}

fn extract_timezone_line(line: String) -> Result(String, Nil) {
  let trimmed = string.trim(line)
  case string.starts_with(trimmed, "#") {
    True -> Error(Nil)
    False -> {
      case string.split_once(trimmed, on: "timezone:") {
        Ok(#(_, value_part)) -> {
          let value_no_comment = case string.split_once(value_part, on: "#") {
            Ok(#(before, _)) -> before
            Error(_) -> value_part
          }
          let clean_val = string.trim(value_no_comment)
          let clean_val = case string.starts_with(clean_val, "\"") && string.ends_with(clean_val, "\"") {
            True -> string.slice(clean_val, 1, string.length(clean_val) - 2)
            False -> {
              case string.starts_with(clean_val, "'") && string.ends_with(clean_val, "'") {
                True -> string.slice(clean_val, 1, string.length(clean_val) - 2)
                False -> clean_val
              }
            }
          }
          let final_val = string.trim(clean_val)
          case final_val {
            "" -> Error(Nil)
            _ -> Ok(final_val)
          }
        }
        Error(_) -> Error(Nil)
      }
    }
  }
}

pub fn validate_timezone(name: String) -> Bool {
  case string.contains(name, "..") || string.starts_with(name, "/") {
    True -> False
    False -> {
      let path = "/usr/share/zoneinfo/" <> name
      case simplifile.is_file(path) {
        Ok(True) -> True
        _ -> False
      }
    }
  }
}

pub fn resolve_timezone_name() -> String {
  case get_env("HERMES_TIMEZONE") {
    Ok(tz) -> string.trim(tz)
    Error(_) -> {
      let config_file = get_config_path()
      case simplifile.read(config_file) {
        Ok(content) -> {
          case parse_timezone_from_yaml(content) {
            Ok(tz) -> tz
            Error(_) -> ""
          }
        }
        Error(_) -> ""
      }
    }
  }
}

fn handle_message(state: CacheState, message: Message) -> actor.Next(CacheState, Message) {
  case message {
    ResetCache -> {
      actor.continue(CacheState(resolved: False, timezone_name: None))
    }
    GetTimezone(reply_to) -> {
      case state.resolved {
        True -> {
          actor.send(reply_to, state.timezone_name)
          actor.continue(state)
        }
        False -> {
          let name = resolve_timezone_name()
          let tz = case name {
            "" -> None
            _ -> {
              case validate_timezone(name) {
                True -> Some(name)
                False -> {
                  io.println("Warning: Invalid timezone '" <> name <> "'. Falling back to server local time.")
                  None
                }
              }
            }
          }
          actor.send(reply_to, tz)
          actor.continue(CacheState(resolved: True, timezone_name: tz))
        }
      }
    }
  }
}

pub fn get_cache_pid() -> Pid {
  case whereis_cache() {
    Ok(pid) -> pid
    Error(_) -> {
      let assert Ok(started) =
        actor.new_with_initialiser(1000, fn(subject) {
          let selector =
            process.new_selector()
            |> process.select_other(fn(dyn_msg) {
              unsafe_coerce(dyn_msg)
            })
          
          actor.initialised(CacheState(resolved: False, timezone_name: None))
          |> actor.selecting(selector)
          |> actor.returning(subject)
          |> Ok
        })
        |> actor.on_message(handle_message)
        |> actor.start
      
      let pid = started.pid
      let _ = register_cache(pid)
      pid
    }
  }
}

@external(erlang, "hermes_time_ffi", "identity")
fn unsafe_coerce(x: Dynamic) -> Message


pub fn get_timezone() -> Option(String) {
  let pid = get_cache_pid()
  let self_subject = process.new_subject()
  let msg = GetTimezone(self_subject)
  let _ = send_to_cache_pid(pid, msg)
  case process.receive(self_subject, 5000) {
    Ok(tz) -> tz
    Error(_) -> None
  }
}

pub fn reset_cache() -> Nil {
  let pid = get_cache_pid()
  let _ = send_to_cache_pid(pid, ResetCache)
  Nil
}

pub fn get_local_timezone_name() -> String {
  case read_link("/etc/localtime") {
    Ok(target) -> {
      case string.split_once(target, on: "/zoneinfo/") {
        Ok(#(_, name)) -> name
        Error(_) -> "Local"
      }
    }
    Error(_) -> "Local"
  }
}

pub fn get_server_local_time() -> DateTime {
  let local = erl_local_time()
  let utc = erl_universal_time()
  let local_secs = erl_datetime_to_gregorian_seconds(local)
  let utc_secs = erl_datetime_to_gregorian_seconds(utc)
  let offset = local_secs - utc_secs
  
  let #(#(year, month, day), #(hour, minute, second)) = local
  let tz_name = get_local_timezone_name()
  
  DateTime(
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
    second: second,
    offset_seconds: offset,
    timezone_name: tz_name,
  )
}

fn parse_offset_string(offset: String) -> Int {
  let clean = string.trim(offset)
  case string.pop_grapheme(clean) {
    Ok(#(sign, rest)) -> {
      case string.length(rest) {
        4 -> {
          let hrs_str = string.slice(rest, 0, 2)
          let mins_str = string.slice(rest, 2, 2)
          case int.parse(hrs_str), int.parse(mins_str) {
            Ok(hrs), Ok(mins) -> {
              let total_secs = { hrs * 3600 + mins * 60 }
              case sign {
                "-" -> -total_secs
                _ -> total_secs
              }
            }
            _, _ -> 0
          }
        }
        _ -> 0
      }
    }
    Error(_) -> 0
  }
}

fn parse_date_output(output: String, tz_name: String) -> Result(DateTime, Nil) {
  let cleaned = string.trim(output)
  let parts = string.split(cleaned, on: " ")
  case parts {
    [yr, mo, dy, hr, min, sec, tz_offset] -> {
      use year <- result.try(int.parse(yr))
      use month <- result.try(int.parse(mo))
      use day <- result.try(int.parse(dy))
      use hour <- result.try(int.parse(hr))
      use minute <- result.try(int.parse(min))
      use second <- result.try(int.parse(sec))
      let offset_seconds = parse_offset_string(tz_offset)
      Ok(DateTime(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second,
        offset_seconds: offset_seconds,
        timezone_name: tz_name,
      ))
    }
    _ -> Error(Nil)
  }
}

pub fn now() -> DateTime {
  let tz = get_timezone()
  case tz {
    Some(tz_name) -> {
      let cmd = "TZ=\"" <> tz_name <> "\" date \"+%Y %m %d %H %M %S %z\""
      let output = run_command(cmd)
      case parse_date_output(output, tz_name) {
        Ok(dt) -> dt
        Error(_) -> {
          get_server_local_time()
        }
      }
    }
    None -> {
      get_server_local_time()
    }
  }
}
