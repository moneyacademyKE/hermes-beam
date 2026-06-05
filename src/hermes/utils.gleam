import gleam/dynamic.{type Dynamic}
import gleam/string
import gleam/list
import gleam/int
import gleam/float
import gleam/option.{type Option, Some, None}
import gleam/erlang/os
import gleam/uri
import filepath
import simplifile
import gleam/json
import gleam/bit_array
import gleam/string_builder.{type StringBuilder}

// ─── FFI Bindings to Erlang ──────────────────────────────────────────────────

@external(erlang, "utils_ffi", "identity")
pub fn from(x: a) -> Dynamic

@external(erlang, "utils_ffi", "read_link")
fn erl_read_link(path: String) -> Result(String, Dynamic)

@external(erlang, "utils_ffi", "rename")
fn erl_rename(from: String, to: String) -> Result(Nil, Dynamic)

@external(erlang, "utils_ffi", "open_temp_file")
fn erl_open_temp_file(path: String) -> Result(Dynamic, Dynamic)

@external(erlang, "utils_ffi", "write")
fn erl_write(fd: Dynamic, data: BitArray) -> Result(Nil, Dynamic)

@external(erlang, "utils_ffi", "sync")
fn erl_sync(fd: Dynamic) -> Result(Nil, Dynamic)

@external(erlang, "utils_ffi", "close")
fn erl_close(fd: Dynamic) -> Result(Nil, Dynamic)

@external(erlang, "utils_ffi", "delete")
fn erl_delete(path: String) -> Result(Nil, Dynamic)

@external(erlang, "utils_ffi", "unique_integer")
fn erl_unique_integer() -> Int

@external(erlang, "utils_ffi", "putenv")
fn putenv(key: String, value: String) -> Dynamic

// ─── AST Definition for JSON/YAML serialization ──────────────────────────────

pub type Yaml {
  YamlNull
  YamlBool(Bool)
  YamlInt(Int)
  YamlFloat(Float)
  YamlString(String)
  YamlList(List(Yaml))
  YamlMap(List(#(String, Yaml)))
}

// ─── Truthy Coercion Helpers ─────────────────────────────────────────────────

pub fn is_truthy_value(value: Dynamic, default: Bool) -> Bool {
  case dynamic.bool(value) {
    Ok(b) -> b
    Error(_) -> {
      case dynamic.string(value) {
        Ok(s) -> {
          let clean = string.lowercase(string.trim(s))
          list.contains(["1", "true", "yes", "on"], clean)
        }
        Error(_) -> {
          case string.inspect(value) {
            "Nil" | "nil" -> default
            _ -> {
              case dynamic.int(value) {
                Ok(i) -> i != 0
                Error(_) -> {
                  case dynamic.float(value) {
                    Ok(f) -> f != 0.0
                    Error(_) -> {
                      case dynamic.list(value) {
                        Ok(l) -> !list.is_empty(l)
                        Error(_) -> default
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

pub fn env_var_enabled(name: String, default: String) -> Bool {
  let val = case os.get_env(name) {
    Ok(v) -> v
    Error(Nil) -> default
  }
  is_truthy_value(from(val), False)
}

pub fn env_int(key: String, default: Int) -> Int {
  case os.get_env(key) {
    Ok(val) -> {
      case int.parse(string.trim(val)) {
        Ok(i) -> i
        Error(Nil) -> default
      }
    }
    Error(Nil) -> default
  }
}

pub fn env_bool(key: String, default: Bool) -> Bool {
  case os.get_env(key) {
    Ok(val) -> is_truthy_value(from(val), default)
    Error(Nil) -> default
  }
}

// ─── Proxy URL Normalization ─────────────────────────────────────────────────

pub fn normalize_proxy_url(proxy_url: Option(String)) -> Option(String) {
  case proxy_url {
    None -> None
    Some(url) -> {
      let candidate = string.trim(url)
      case string.is_empty(candidate) {
        True -> None
        False -> {
          let lower = string.lowercase(candidate)
          case string.starts_with(lower, "socks://") {
            True -> Some("socks5://" <> string.drop_left(candidate, 8))
            False -> Some(candidate)
          }
        }
      }
    }
  }
}

const proxy_env_keys = [
  "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy",
  "all_proxy",
]

pub fn normalize_proxy_env_vars() -> Nil {
  list.each(proxy_env_keys, fn(key) {
    case os.get_env(key) {
      Ok(value) -> {
        case normalize_proxy_url(Some(value)) {
          Some(normalized) -> {
            case normalized != value {
              True -> {
                putenv(key, normalized)
                Nil
              }
              False -> Nil
            }
          }
          None -> Nil
        }
      }
      Error(_) -> Nil
    }
  })
}

// ─── URL Parsing ─────────────────────────────────────────────────────────────

pub fn base_url_hostname(base_url: String) -> String {
  let raw = string.trim(base_url)
  case string.is_empty(raw) {
    True -> ""
    False -> {
      let url_to_parse = case string.contains(raw, "://") {
        True -> raw
        False -> "//" <> raw
      }
      case uri.parse(url_to_parse) {
        Ok(parsed) -> {
          case parsed.host {
            Some(host) -> {
              let lower_host = string.lowercase(host)
              strip_trailing_dot(lower_host)
            }
            None -> ""
          }
        }
        Error(_) -> ""
      }
    }
  }
}

fn strip_trailing_dot(s: String) -> String {
  case string.ends_with(s, ".") {
    True -> strip_trailing_dot(string.drop_right(s, 1))
    False -> s
  }
}

pub fn base_url_host_matches(base_url: String, domain: String) -> Bool {
  let hostname = base_url_hostname(base_url)
  let domain_clean =
    domain
    |> string.trim()
    |> string.lowercase()
    |> strip_trailing_dot()

  case hostname == "", domain_clean == "" {
    True, _ | _, True -> False
    False, False -> {
      hostname == domain_clean || string.ends_with(hostname, "." <> domain_clean)
    }
  }
}

// ─── Symlinks & Permissions ──────────────────────────────────────────────────

pub fn is_link(path: String) -> Bool {
  case erl_read_link(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn realpath(path: String) -> String {
  do_realpath(path, [])
}

fn do_realpath(path: String, visited: List(String)) -> String {
  case list.contains(visited, path) {
    True -> path
    False -> {
      case erl_read_link(path) {
        Ok(target) -> {
          let resolved = case filepath.is_absolute(target) {
            True -> target
            False -> filepath.join(filepath.directory_name(path), target)
          }
          do_realpath(resolved, [path, ..visited])
        }
        Error(_) -> path
      }
    }
  }
}

pub fn preserve_file_mode(path: String) -> Option(Int) {
  case simplifile.file_info(path) {
    Ok(info) -> Some(simplifile.file_info_permissions_octal(info))
    Error(_) -> None
  }
}

pub fn restore_file_mode(path: String, mode: Option(Int)) -> Nil {
  case mode {
    Some(m) -> {
      let _ = simplifile.set_permissions_octal(path, m)
      Nil
    }
    None -> Nil
  }
}

pub fn atomic_replace(tmp_path: String, target: String) -> Result(String, String) {
  let real_path = case is_link(target) {
    True -> realpath(target)
    False -> target
  }
  case erl_rename(tmp_path, real_path) {
    Ok(_) -> Ok(real_path)
    Error(err) -> Error(string.inspect(err))
  }
}

// ─── Temporary File Logic ────────────────────────────────────────────────────

pub fn stem(path: String) -> String {
  let base = filepath.base_name(path)
  case string.split(base, ".") {
    [] -> ""
    [first, ..rest] -> {
      case rest {
        [] -> first
        _ -> {
          let len = list.length(rest)
          let prefix = list.take(rest, len - 1)
          string.join([first, ..prefix], ".")
        }
      }
    }
  }
}

fn make_temp_path(parent: String, stem_val: String) -> String {
  let rand_val = erl_unique_integer()
  let name = "." <> stem_val <> "_" <> int.to_string(rand_val) <> ".tmp"
  filepath.join(parent, name)
}

fn create_temp_file(
  parent: String,
  stem_val: String,
  retries: Int,
) -> Result(#(Dynamic, String), String) {
  case retries <= 0 {
    True -> Error("Failed to create unique temp file")
    False -> {
      let tmp_path = make_temp_path(parent, stem_val)
      case erl_open_temp_file(tmp_path) {
        Ok(fd) -> Ok(#(fd, tmp_path))
        Error(_) -> create_temp_file(parent, stem_val, retries - 1)
      }
    }
  }
}

// ─── JSON Helper and Pretty Printer ──────────────────────────────────────────

pub fn safe_json_loads(text: String, default: Dynamic) -> Dynamic {
  case json.decode(from: text, using: dynamic.dynamic) {
    Ok(val) -> val
    Error(_) -> default
  }
}

pub fn yaml_to_json(val: Yaml) -> json.Json {
  case val {
    YamlNull -> json.null()
    YamlBool(b) -> json.bool(b)
    YamlInt(i) -> json.int(i)
    YamlFloat(f) -> json.float(f)
    YamlString(s) -> json.string(s)
    YamlList(items) -> json.array(items, yaml_to_json)
    YamlMap(pairs) -> {
      let json_pairs =
        list.map(pairs, fn(p) {
          let #(k, v) = p
          #(k, yaml_to_json(v))
        })
      json.object(json_pairs)
    }
  }
}

pub fn format_json(json_str: String, indent_spaces: Int) -> String {
  let chars = string.to_graphemes(json_str)
  do_format_json(chars, False, False, 0, indent_spaces, string_builder.new())
}

fn do_format_json(
  chars: List(String),
  in_string: Bool,
  escaped: Bool,
  level: Int,
  indent_spaces: Int,
  acc: StringBuilder,
) -> String {
  case chars {
    [] -> string_builder.to_string(acc)
    [c, ..rest] -> {
      case in_string {
        True -> {
          case escaped {
            True ->
              do_format_json(
                rest,
                True,
                False,
                level,
                indent_spaces,
                string_builder.append(acc, c),
              )
            False -> {
              case c {
                "\\" ->
                  do_format_json(
                    rest,
                    True,
                    True,
                    level,
                    indent_spaces,
                    string_builder.append(acc, c),
                  )
                "\"" ->
                  do_format_json(
                    rest,
                    False,
                    False,
                    level,
                    indent_spaces,
                    string_builder.append(acc, c),
                  )
                _ ->
                  do_format_json(
                    rest,
                    True,
                    False,
                    level,
                    indent_spaces,
                    string_builder.append(acc, c),
                  )
              }
            }
          }
        }
        False -> {
          case c {
            "\"" ->
              do_format_json(
                rest,
                True,
                False,
                level,
                indent_spaces,
                string_builder.append(acc, c),
              )
            "{" | "[" -> {
              let next_level = level + 1
              let new_acc =
                acc
                |> string_builder.append(c)
                |> string_builder.append("\n")
                |> string_builder.append(string.repeat(
                  " ",
                  next_level * indent_spaces,
                ))
              do_format_json(rest, False, False, next_level, indent_spaces, new_acc)
            }
            "}" | "]" -> {
              let next_level = int.max(0, level - 1)
              let new_acc =
                acc
                |> string_builder.append("\n")
                |> string_builder.append(string.repeat(
                  " ",
                  next_level * indent_spaces,
                ))
                |> string_builder.append(c)
              do_format_json(rest, False, False, next_level, indent_spaces, new_acc)
            }
            "," -> {
              let new_acc =
                acc
                |> string_builder.append(c)
                |> string_builder.append("\n")
                |> string_builder.append(string.repeat(" ", level * indent_spaces))
              do_format_json(rest, False, False, level, indent_spaces, new_acc)
            }
            ":" -> {
              let new_acc =
                acc
                |> string_builder.append(c)
                |> string_builder.append(" ")
              do_format_json(rest, False, False, level, indent_spaces, new_acc)
            }
            " " | "\n" | "\r" | "\t" -> {
              do_format_json(rest, False, False, level, indent_spaces, acc)
            }
            _ ->
              do_format_json(
                rest,
                False,
                False,
                level,
                indent_spaces,
                string_builder.append(acc, c),
              )
          }
        }
      }
    }
  }
}

pub fn atomic_json_write(
  path: String,
  data: Yaml,
  mode: Option(Int),
) -> Result(Nil, String) {
  let parent = filepath.directory_name(path)
  let _ = simplifile.create_directory_all(parent)

  let original_mode = case mode {
    Some(_) -> None
    None -> preserve_file_mode(path)
  }

  let stem_val = stem(path)
  case create_temp_file(parent, stem_val, 10) {
    Ok(#(fd, tmp_path)) -> {
      let minified_json = json.to_string(yaml_to_json(data))
      let formatted_json = format_json(minified_json, 2)
      let bytes = bit_array.from_string(formatted_json)
      let write_res = case erl_write(fd, bytes) {
        Ok(_) -> {
          case erl_sync(fd) {
            Ok(_) -> Ok(Nil)
            Error(err) -> Error("Failed to sync file: " <> string.inspect(err))
          }
        }
        Error(err) -> Error("Failed to write to file: " <> string.inspect(err))
      }
      let _ = erl_close(fd)

      case write_res {
        Ok(_) -> {
          case atomic_replace(tmp_path, path) {
            Ok(real_path) -> {
              case mode {
                Some(m) -> {
                  let _ = simplifile.set_permissions_octal(real_path, m)
                  Nil
                }
                None -> restore_file_mode(real_path, original_mode)
              }
              Ok(Nil)
            }
            Error(err) -> {
              let _ = erl_delete(tmp_path)
              Error(err)
            }
          }
        }
        Error(err) -> {
          let _ = erl_delete(tmp_path)
          Error(err)
        }
      }
    }
    Error(err) -> Error(err)
  }
}

// ─── YAML Serialization & Atomic Updates ─────────────────────────────────────

pub fn yaml_to_string(value: Yaml) -> String {
  string.trim(do_yaml_to_string(value, 0))
}

fn do_yaml_to_string(value: Yaml, indent_level: Int) -> String {
  let indent = string.repeat("  ", indent_level)
  case value {
    YamlNull -> "null"
    YamlBool(True) -> "true"
    YamlBool(False) -> "false"
    YamlInt(i) -> int.to_string(i)
    YamlFloat(f) -> float.to_string(f)
    YamlString(s) -> {
      let needs_quotes =
        string.is_empty(s)
        || string.starts_with(s, " ")
        || string.ends_with(s, " ")
        || string.contains(s, ":")
        || string.contains(s, "#")
        || string.contains(s, "-")
        || string.contains(s, "[")
        || string.contains(s, "]")
        || string.contains(s, "{")
        || string.contains(s, "}")
      case needs_quotes {
        True -> "\"" <> string.replace(s, "\"", "\\\"") <> "\""
        False -> s
      }
    }
    YamlList(items) -> {
      case items {
        [] -> "[]"
        _ -> {
          let lines =
            list.map(items, fn(item) {
              case item {
                YamlList(_) | YamlMap(_) -> {
                  let item_str = do_yaml_to_string(item, indent_level + 1)
                  indent <> "- \n" <> item_str
                }
                _ -> {
                  let item_str = do_yaml_to_string(item, indent_level + 1)
                  indent <> "- " <> string.trim(item_str)
                }
              }
            })
          string.join(lines, "\n")
        }
      }
    }
    YamlMap(pairs) -> {
      case pairs {
        [] -> "{}"
        _ -> {
          let lines =
            list.map(pairs, fn(pair) {
              let #(k, v) = pair
              case v {
                YamlList(_) | YamlMap(_) -> {
                  let val_str = do_yaml_to_string(v, indent_level + 1)
                  indent <> k <> ":\n" <> val_str
                }
                _ -> {
                  let val_str = do_yaml_to_string(v, indent_level)
                  indent <> k <> ": " <> string.trim(val_str)
                }
              }
            })
          string.join(lines, "\n")
        }
      }
    }
  }
}

pub fn atomic_yaml_write(
  path: String,
  data: Yaml,
  mode: Option(Int),
) -> Result(Nil, String) {
  let parent = filepath.directory_name(path)
  let _ = simplifile.create_directory_all(parent)

  let original_mode = case mode {
    Some(_) -> None
    None -> preserve_file_mode(path)
  }

  let stem_val = stem(path)
  case create_temp_file(parent, stem_val, 10) {
    Ok(#(fd, tmp_path)) -> {
      let yaml_content = yaml_to_string(data)
      let bytes = bit_array.from_string(yaml_content)
      let write_res = case erl_write(fd, bytes) {
        Ok(_) -> {
          case erl_sync(fd) {
            Ok(_) -> Ok(Nil)
            Error(err) -> Error("Failed to sync file: " <> string.inspect(err))
          }
        }
        Error(err) -> Error("Failed to write to file: " <> string.inspect(err))
      }
      let _ = erl_close(fd)

      case write_res {
        Ok(_) -> {
          case atomic_replace(tmp_path, path) {
            Ok(real_path) -> {
              case mode {
                Some(m) -> {
                  let _ = simplifile.set_permissions_octal(real_path, m)
                  Nil
                }
                None -> restore_file_mode(real_path, original_mode)
              }
              Ok(Nil)
            }
            Error(err) -> {
              let _ = erl_delete(tmp_path)
              Error(err)
            }
          }
        }
        Error(err) -> {
          let _ = erl_delete(tmp_path)
          Error(err)
        }
      }
    }
    Error(err) -> Error(err)
  }
}

pub fn atomic_roundtrip_yaml_update(
  path: String,
  key_path: String,
  value: Yaml,
) -> Result(Nil, String) {
  case simplifile.read(path) {
    Ok(content) -> {
      let updated = update_yaml_lines(content, key_path, value)
      let parent = filepath.directory_name(path)
      let stem_val = stem(path)
      let original_mode = preserve_file_mode(path)
      case create_temp_file(parent, stem_val, 10) {
        Ok(#(fd, tmp_path)) -> {
          let bytes = bit_array.from_string(updated)
          let write_res = case erl_write(fd, bytes) {
            Ok(_) -> {
              case erl_sync(fd) {
                Ok(_) -> Ok(Nil)
                Error(err) -> Error("Failed to sync file: " <> string.inspect(err))
              }
            }
            Error(err) -> Error("Failed to write to file: " <> string.inspect(err))
          }
          let _ = erl_close(fd)
          case write_res {
            Ok(_) -> {
              case atomic_replace(tmp_path, path) {
                Ok(real_path) -> {
                  restore_file_mode(real_path, original_mode)
                  Ok(Nil)
                }
                Error(err) -> {
                  let _ = erl_delete(tmp_path)
                  Error(err)
                }
              }
            }
            Error(err) -> {
              let _ = erl_delete(tmp_path)
              Error(err)
            }
          }
        }
        Error(err) -> Error(err)
      }
    }
    Error(_) -> {
      let keys = string.split(key_path, ".")
      let data = build_nested_yaml(keys, value)
      atomic_yaml_write(path, data, None)
    }
  }
}

fn build_nested_yaml(keys: List(String), value: Yaml) -> Yaml {
  case keys {
    [] -> value
    [k] -> YamlMap([#(k, value)])
    [k, ..rest] -> YamlMap([#(k, build_nested_yaml(rest, value))])
  }
}

fn update_yaml_lines(content: String, key_path: String, value: Yaml) -> String {
  let lines = string.split(content, "\n")
  let keys = string.split(key_path, ".")
  let val_str = yaml_value_only_string(value)

  let updated_lines = do_update_yaml_lines(lines, keys, 0, val_str, [])
  string.join(updated_lines, "\n")
}

fn yaml_value_only_string(value: Yaml) -> String {
  case value {
    YamlNull -> "null"
    YamlBool(True) -> "true"
    YamlBool(False) -> "false"
    YamlInt(i) -> int.to_string(i)
    YamlFloat(f) -> float.to_string(f)
    YamlString(s) -> s
    _ -> yaml_to_string(value)
  }
}

fn do_update_yaml_lines(
  lines: List(String),
  keys: List(String),
  current_indent: Int,
  new_val: String,
  acc: List(String),
) -> List(String) {
  case keys {
    [] -> list.reverse(acc) |> list.append(lines)
    [k, ..rest_keys] -> {
      case lines {
        [] -> {
          let indent_str = string.repeat("  ", current_indent)
          let line = indent_str <> k <> ": " <> new_val
          case rest_keys {
            [] -> list.reverse([line, ..acc])
            _ -> {
              let next_acc = [indent_str <> k <> ":", ..acc]
              do_update_yaml_lines([], rest_keys, current_indent + 1, new_val, next_acc)
            }
          }
        }
        [line, ..rest_lines] -> {
          let trimmed = string.trim_left(line)
          let prefix = k <> ":"
          case string.starts_with(trimmed, prefix) {
            True -> {
              case rest_keys {
                [] -> {
                  let indent_len = string.length(line) - string.length(trimmed)
                  let indent_str = string.repeat(" ", indent_len)
                  let updated_line = indent_str <> k <> ": " <> new_val
                  list.reverse([updated_line, ..acc]) |> list.append(rest_lines)
                }
                _ -> {
                  let indent_len = string.length(line) - string.length(trimmed)
                  do_update_yaml_lines(
                    rest_lines,
                    rest_keys,
                    indent_len / 2 + 1,
                    new_val,
                    [line, ..acc],
                  )
                }
              }
            }
            False -> {
              do_update_yaml_lines(
                rest_lines,
                keys,
                current_indent,
                new_val,
                [line, ..acc],
              )
            }
          }
        }
      }
    }
  }
}
