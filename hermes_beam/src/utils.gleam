import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/string
import gleam/option.{type Option, Some, None}
import gleam/list
import gleam/int
import gleam/json
import simplifile

pub type YamlData {
  YamlMap(List(#(String, YamlData)))
  YamlString(String)
  YamlInt(Int)
}

@external(erlang, "gleam_stdlib", "is_null")
@external(javascript, "../gleam_stdlib.mjs", "is_null")
pub fn is_null(a: Dynamic) -> Bool

pub fn is_truthy_value(value: Dynamic, default: Bool) -> Bool {
  case decode.run(value, decode.bool) {
    Ok(b) -> b
    Error(_) -> {
      case decode.run(value, decode.string) {
        Ok(s) -> {
          let s_lower = string.lowercase(string.trim(s))
          s_lower == "1" || s_lower == "true" || s_lower == "yes" || s_lower == "on"
        }
        Error(_) -> {
          case is_null(value) {
            True -> default
            False -> {
              case decode.run(value, decode.int) {
                Ok(i) -> i != 0
                Error(_) -> default
              }
            }
          }
        }
      }
    }
  }
}

pub fn normalize_proxy_url(proxy_url: Option(String)) -> Option(String) {
  case proxy_url {
    None -> None
    Some(url) -> {
      let trimmed = string.trim(url)
      case trimmed {
        "" -> None
        _ -> {
          case string.starts_with(string.lowercase(trimmed), "socks://") {
            True -> Some("socks5://" <> string.drop_start(trimmed, 8))
            False -> Some(trimmed)
          }
        }
      }
    }
  }
}

pub fn trim_trailing_dot(s: String) -> String {
  case string.ends_with(s, ".") {
    True -> trim_trailing_dot(string.drop_end(s, 1))
    False -> s
  }
}

pub fn base_url_hostname(base_url: String) -> String {
  let raw = string.trim(base_url)
  case raw {
    "" -> ""
    _ -> {
      let without_scheme = case string.split_once(raw, "://") {
        Ok(#(_, rest)) -> rest
        Error(_) -> {
          case string.starts_with(raw, "//") {
            True -> string.drop_start(raw, 2)
            False -> raw
          }
        }
      }
      let host_part = case string.split_once(without_scheme, "/") {
        Ok(#(before, _)) -> before
        Error(_) -> without_scheme
      }
      let host_part = case string.split_once(host_part, "?") {
        Ok(#(before, _)) -> before
        Error(_) -> host_part
      }
      let host_part = case string.split_once(host_part, "#") {
        Ok(#(before, _)) -> before
        Error(_) -> host_part
      }
      let host_only = case string.split_once(host_part, ":") {
        Ok(#(before, _)) -> before
        Error(_) -> host_part
      }
      
      string.lowercase(host_only)
      |> trim_trailing_dot
    }
  }
}

pub fn base_url_host_matches(base_url: String, domain: String) -> Bool {
  let hostname = base_url_hostname(base_url)
  let domain = string.lowercase(string.trim(domain))
  let domain = trim_trailing_dot(domain)
  case hostname == "" || domain == "" {
    True -> False
    False -> {
      hostname == domain || string.ends_with(hostname, "." <> domain)
    }
  }
}

pub fn yaml_to_json(data: YamlData) -> json.Json {
  case data {
    YamlMap(pairs) -> {
      json.object(list.map(pairs, fn(pair) {
        #(pair.0, yaml_to_json(pair.1))
      }))
    }
    YamlString(s) -> json.string(s)
    YamlInt(i) -> json.int(i)
  }
}

pub fn yaml_to_string(data: YamlData, indent: Int) -> String {
  let spacing = string.repeat(" ", indent)
  case data {
    YamlMap(pairs) -> {
      list.map(pairs, fn(pair) {
        let key = pair.0
        case pair.1 {
          YamlMap(nested_pairs) -> {
            spacing <> key <> ":\n" <> yaml_to_string(YamlMap(nested_pairs), indent + 2)
          }
          YamlString(s) -> {
            spacing <> key <> ": " <> s
          }
          YamlInt(i) -> {
            spacing <> key <> ": " <> int.to_string(i)
          }
        }
      })
      |> string.join("\n")
    }
    YamlString(s) -> s
    YamlInt(i) -> int.to_string(i)
  }
}

pub fn atomic_json_write(path: String, data: YamlData, mode: Option(Int)) -> Result(Nil, simplifile.FileError) {
  let content = json.to_string(yaml_to_json(data))
  let temp_path = path <> ".tmp"
  case simplifile.write(temp_path, content) {
    Ok(_) -> {
      case mode {
        Some(m) -> {
          let _ = simplifile.set_permissions_octal(temp_path, m)
          Nil
        }
        None -> Nil
      }
      case simplifile.rename(temp_path, path) {
        Ok(_) -> Ok(Nil)
        Error(err) -> {
          let _ = simplifile.delete(temp_path)
          Error(err)
        }
      }
    }
    Error(err) -> Error(err)
  }
}

pub fn atomic_yaml_write(path: String, data: YamlData, mode: Option(Int)) -> Result(Nil, simplifile.FileError) {
  let content = yaml_to_string(data, 0)
  let temp_path = path <> ".tmp"
  case simplifile.write(temp_path, content) {
    Ok(_) -> {
      case mode {
        Some(m) -> {
          let _ = simplifile.set_permissions_octal(temp_path, m)
          Nil
        }
        None -> Nil
      }
      case simplifile.rename(temp_path, path) {
        Ok(_) -> Ok(Nil)
        Error(err) -> {
          let _ = simplifile.delete(temp_path)
          Error(err)
        }
      }
    }
    Error(err) -> Error(err)
  }
}

@external(erlang, "utils_ffi", "format_float")
pub fn format_float(val: Float) -> String

@external(erlang, "utils_ffi", "read_line")
pub fn read_line(prompt: String) -> Result(String, Dynamic)

@external(erlang, "utils_ffi", "get_cwd")
pub fn get_cwd() -> Result(String, Dynamic)


