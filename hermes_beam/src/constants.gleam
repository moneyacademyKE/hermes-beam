import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

pub type Token {
  Token(Option(String))
}

pub type ReasoningEffort {
  ReasoningEffort(enabled: Bool, effort: Option(String))
}

// ─── Constants ──────────────────────────────────────────────────────────────

pub const valid_reasoning_efforts = ["minimal", "low", "medium", "high", "xhigh"]

pub const partial_stream_stub_id = "partial-stream-stub"

pub const finish_reason_length = "length"

pub const openrouter_base_url = "https://openrouter.ai/api/v1"

pub const openrouter_models_url = "https://openrouter.ai/api/v1/models"

// ─── External FFI Declarations ──────────────────────────────────────────────

@external(erlang, "hermes_constants_ffi", "is_windows")
pub fn is_windows() -> Bool

@external(erlang, "hermes_constants_ffi", "get_user_home")
pub fn get_user_home() -> String

@external(erlang, "hermes_constants_ffi", "get_env")
fn ffi_get_env(key: String) -> Result(String, Nil)

pub fn get_env(key: String) -> Option(String) {
  case ffi_get_env(key) {
    Ok(val) -> Some(val)
    Error(_) -> None
  }
}

@external(erlang, "hermes_constants_ffi", "set_env")
pub fn set_env(key: String, value: String) -> Nil

@external(erlang, "hermes_constants_ffi", "change_mode")
fn change_mode(path: String, mode: Int) -> Result(Nil, Nil)

@external(erlang, "hermes_constants_ffi", "get_home_override")
fn ffi_get_home_override() -> Result(String, Nil)

@external(erlang, "hermes_constants_ffi", "set_home_override")
fn ffi_set_home_override(value: String) -> Nil

@external(erlang, "hermes_constants_ffi", "erase_home_override")
fn ffi_erase_home_override() -> Nil

@external(erlang, "hermes_constants_ffi", "get_fallback_warned")
fn ffi_get_fallback_warned() -> Bool

@external(erlang, "hermes_constants_ffi", "set_fallback_warned")
fn ffi_set_fallback_warned() -> Nil

@external(erlang, "hermes_constants_ffi", "get_packaged_data_dir")
fn ffi_get_packaged_data_dir(name: String) -> Result(String, Nil)

@external(erlang, "hermes_constants_ffi", "write_stderr")
fn write_stderr(msg: String) -> Nil

@external(erlang, "hermes_constants_ffi", "apply_ipv4_preference")
fn ffi_apply_ipv4_preference(force: Bool) -> Nil

@external(erlang, "hermes_constants_ffi", "resolve_path")
pub fn resolve_path(path: String) -> String

@external(erlang, "filename", "join")
pub fn path_join(base: String, sub: String) -> String

@external(erlang, "filename", "dirname")
pub fn dirname(path: String) -> String

@external(erlang, "filename", "basename")
pub fn basename(path: String) -> String

@external(erlang, "hermes_constants_ffi", "is_wsl")
pub fn is_wsl() -> Bool

@external(erlang, "hermes_constants_ffi", "is_container")
pub fn is_container() -> Bool

// ─── Implementation Functions ──────────────────────────────────────────────

pub fn get_hermes_home_override() -> Option(String) {
  case ffi_get_home_override() {
    Ok(val) -> Some(val)
    Error(_) -> None
  }
}

pub fn set_hermes_home_override(path: Option(String)) -> Token {
  let prev = get_hermes_home_override()
  case path {
    Some(val) -> ffi_set_home_override(val)
    None -> ffi_erase_home_override()
  }
  Token(prev)
}

pub fn reset_hermes_home_override(token: Token) -> Nil {
  let Token(prev) = token
  case prev {
    Some(val) -> ffi_set_home_override(val)
    None -> ffi_erase_home_override()
  }
  Nil
}

pub fn get_platform_default_hermes_home() -> String {
  case is_windows() {
    True -> {
      let local_appdata = case get_env("LOCALAPPDATA") {
        Some(val) -> string.trim(val)
        None -> ""
      }
      let base = case local_appdata != "" {
        True -> local_appdata
        False -> path_join(path_join(get_user_home(), "AppData"), "Local")
      }
      path_join(base, "hermes")
    }
    False -> {
      path_join(get_user_home(), ".hermes")
    }
  }
}

pub fn get_hermes_home() -> String {
  case get_hermes_home_override() {
    Some(override) -> override
    None -> {
      let env_val = get_env("HERMES_HOME")
      case env_val {
        Some(val) -> {
          let trimmed = string.trim(val)
          case trimmed == "" {
            True -> get_hermes_home_fallback()
            False -> trimmed
          }
        }
        None -> get_hermes_home_fallback()
      }
    }
  }
}

fn get_hermes_home_fallback() -> String {
  case ffi_get_fallback_warned() {
    True -> Nil
    False -> {
      ffi_set_fallback_warned()
      let fallback_home = get_platform_default_hermes_home()
      let active_path = path_join(fallback_home, "active_profile")
      let active = case simplifile.read(active_path) {
        Ok(content) -> string.trim(content)
        Error(_) -> ""
      }
      case active != "" && active != "default" {
        True -> {
          let msg =
            "[HERMES_HOME fallback] HERMES_HOME is unset but active profile is '"
            <> active
            <> "'. Falling back to "
            <> fallback_home
            <> ", which is the DEFAULT profile — not '"
            <> active
            <> "'. Any data this process writes will land in the wrong profile. "
            <> "The subprocess spawner should pass HERMES_HOME explicitly (see issue #18594).\n"
          write_stderr(msg)
        }
        False -> Nil
      }
    }
  }
  get_platform_default_hermes_home()
}

pub fn get_default_hermes_root() -> String {
  let native_home = get_platform_default_hermes_home()
  let env_home = case get_env("HERMES_HOME") {
    Some(val) -> string.trim(val)
    None -> ""
  }

  case env_home == "" {
    True -> native_home
    False -> {
      case is_relative_to(env_home, native_home) {
        True -> native_home
        False -> {
          let parent = dirname(env_home)
          let parent_name = basename(parent)
          case parent_name == "profiles" {
            True -> dirname(parent)
            False -> env_home
          }
        }
      }
    }
  }
}

fn is_relative_to(child: String, parent: String) -> Bool {
  let resolved_child = resolve_path(child)
  let resolved_parent = resolve_path(parent)
  let sep = case is_windows() {
    True -> "\\"
    False -> "/"
  }
  resolved_child == resolved_parent
  || string.starts_with(resolved_child, resolved_parent <> sep)
}

pub fn get_optional_skills_dir(default: Option(String)) -> String {
  let override = case get_env("HERMES_OPTIONAL_SKILLS") {
    Some(val) -> string.trim(val)
    None -> ""
  }
  case override != "" {
    True -> override
    False -> {
      case ffi_get_packaged_data_dir("optional-skills") {
        Ok(packaged) -> packaged
        Error(_) -> {
          case default {
            Some(def) -> def
            None -> path_join(get_hermes_home(), "optional-skills")
          }
        }
      }
    }
  }
}

pub fn get_optional_mcps_dir(default: Option(String)) -> String {
  let override = case get_env("HERMES_OPTIONAL_MCPS") {
    Some(val) -> string.trim(val)
    None -> ""
  }
  case override != "" {
    True -> override
    False -> {
      case ffi_get_packaged_data_dir("optional-mcps") {
        Ok(packaged) -> packaged
        Error(_) -> {
          case default {
            Some(def) -> def
            None -> path_join(get_hermes_home(), "optional-mcps")
          }
        }
      }
    }
  }
}

pub fn get_bundled_skills_dir(default: Option(String)) -> String {
  let override = case get_env("HERMES_BUNDLED_SKILLS") {
    Some(val) -> string.trim(val)
    None -> ""
  }
  case override != "" {
    True -> override
    False -> {
      case ffi_get_packaged_data_dir("skills") {
        Ok(packaged) -> packaged
        Error(_) -> {
          case default {
            Some(def) -> def
            None -> path_join(get_hermes_home(), "skills")
          }
        }
      }
    }
  }
}

pub fn get_hermes_dir(new_subpath: String, old_name: String) -> String {
  let home = get_hermes_home()
  let old_path = path_join(home, old_name)
  let exists =
    simplifile.is_file(old_path) == Ok(True)
    || simplifile.is_directory(old_path) == Ok(True)
  case exists {
    True -> old_path
    False -> path_join(home, new_subpath)
  }
}

pub fn display_hermes_home() -> String {
  let home = get_hermes_home()
  let user_home = get_user_home()
  case home == user_home {
    True -> "~"
    False -> {
      case is_relative_to(home, user_home) {
        True -> {
          let user_home_len = string.length(user_home)
          let relative = string.drop_start(home, user_home_len)
          let relative_clean =
            case
              string.starts_with(relative, "/")
              || string.starts_with(relative, "\\")
            {
              True -> string.drop_start(relative, 1)
              False -> relative
            }
          "~/" <> relative_clean
        }
        False -> home
      }
    }
  }
}

pub fn secure_parent_dir(path: String) -> Nil {
  let parent = resolve_path(dirname(path))
  let is_win = is_windows()
  let parts = case is_win {
    True -> {
      let clean_parent = string.replace(parent, "\\", "/")
      string.split(clean_parent, "/")
    }
    False -> string.split(parent, "/")
  }

  let num_parts = list.length(parts)
  case parent == "/" || parent == "C:\\" || num_parts < 3 {
    True -> Nil
    False -> {
      let _ = change_mode(parent, 448)
      Nil
    }
  }
}

pub fn get_subprocess_home() -> Option(String) {
  let hermes_home = case get_hermes_home_override() {
    Some(val) -> val
    None -> {
      case get_env("HERMES_HOME") {
        Some(val) -> string.trim(val)
        None -> ""
      }
    }
  }
  case hermes_home == "" {
    True -> None
    False -> {
      let profile_home = path_join(hermes_home, "home")
      case simplifile.is_directory(profile_home) {
        Ok(True) -> Some(profile_home)
        _ -> None
      }
    }
  }
}

pub fn parse_reasoning_effort(effort: String) -> Option(ReasoningEffort) {
  let clean_effort = string.lowercase(string.trim(effort))
  case clean_effort {
    "" -> None
    "none" -> Some(ReasoningEffort(enabled: False, effort: None))
    "minimal" | "low" | "medium" | "high" | "xhigh" ->
      Some(ReasoningEffort(enabled: True, effort: Some(clean_effort)))
    _ -> None
  }
}

pub fn is_termux() -> Bool {
  let termux_ver = case get_env("TERMUX_VERSION") {
    Some(val) -> val
    None -> ""
  }
  let prefix = case get_env("PREFIX") {
    Some(val) -> val
    None -> ""
  }
  termux_ver != "" || string.contains(prefix, "com.termux/files/usr")
}

pub fn get_config_path() -> String {
  path_join(get_hermes_home(), "config.yaml")
}

pub fn get_skills_dir() -> String {
  path_join(get_hermes_home(), "skills")
}

pub fn get_env_path() -> String {
  path_join(get_hermes_home(), ".env")
}

pub fn apply_ipv4_preference(force: Bool) -> Nil {
  ffi_apply_ipv4_preference(force)
}
