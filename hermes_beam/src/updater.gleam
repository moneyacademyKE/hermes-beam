import constants
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

pub type UpdateStatus {
  UpToDate
  UpdateAvailable(version: String, url: String)
  CheckFailed(reason: String)
}

pub type ReleaseInfo {
  ReleaseInfo(
    tag: String,
    download_url: String,
    release_notes: String,
  )
}

pub fn current_version() -> String {
  case constants.get_env("HERMES_VERSION") {
    Some(v) -> v
    None -> "2.0.0"
  }
}

pub fn install_path() -> String {
  case constants.get_env("HERMES_INSTALL_PATH") {
    Some(p) -> p
    None -> constants.get_hermes_home()
  }
}

pub fn check_for_updates() -> UpdateStatus {
  let api_url = "https://api.github.com/repos/criticalinsight/hermes-beam-port/releases/latest"
  case hermes_http_fetch(api_url) {
    Ok(body) -> {
      case parse_release_json(body) {
        Some(info) -> {
          let current = current_version()
          case info.tag == current {
            True -> UpToDate
            False -> UpdateAvailable(info.tag, info.download_url)
          }
        }
        None -> CheckFailed("Failed to parse release info")
      }
    }
    Error(err) -> CheckFailed(err)
  }
}

fn parse_release_json(body: String) -> Option(ReleaseInfo) {
  let tag_decoder = {
    use tag_name <- decode.field("tag_name", decode.string)
    use html_url <- decode.field("html_url", decode.string)
    use body_text <- decode.field("body", decode.string)
    decode.success(ReleaseInfo(
      tag: tag_name,
      download_url: html_url,
      release_notes: body_text,
    ))
  }
  case json.parse(from: body, using: tag_decoder) {
    Ok(info) -> Some(info)
    Error(_) -> None
  }
}

@external(erlang, "hermes_http", "fetch")
fn hermes_http_fetch(url: String) -> Result(String, String)

pub fn auto_update_enabled() -> Bool {
  case constants.get_env("HERMES_AUTO_UPDATE") {
    Some(v) -> {
      case string.lowercase(string.trim(v)) {
        "true" | "1" | "yes" | "on" -> True
        _ -> False
      }
    }
    None -> False
  }
}

pub fn last_check_path() -> String {
  constants.path_join(constants.get_hermes_home(), "update_check.txt")
}

pub fn should_check_on_startup() -> Bool {
  case simplifile.read(last_check_path()) {
    Ok(content) -> {
      let ts = case int.parse(string.trim(content)) {
        Ok(n) -> n
        Error(_) -> 0
      }
      let now = system_time_seconds()
      now - ts > 86_400
    }
    Error(_) -> True
  }
}

pub fn record_check_timestamp() -> Nil {
  let path = last_check_path()
  let _ = simplifile.write(path, int.to_string(system_time_seconds()))
  Nil
}

@external(erlang, "erlang", "system_time")
fn system_time_seconds() -> Int

pub fn startup_check() -> Nil {
  case auto_update_enabled() && should_check_on_startup() {
    False -> Nil
    True -> {
      record_check_timestamp()
      case check_for_updates() {
        UpToDate -> Nil
        UpdateAvailable(version, _url) -> {
          io.println(
            "\n📦 Update available: " <> version <> " (current: " <> current_version() <> ")",
          )
          io.println("   Run 'hermes update' to install.\n")
        }
        CheckFailed(_) -> Nil
      }
    }
  }
}

pub fn format_status() -> String {
  let status = check_for_updates()
  case status {
    UpToDate ->
      "Hermes BEAM v" <> current_version() <> " — up to date"
    UpdateAvailable(version, _) ->
      "Hermes BEAM v" <> current_version() <> " — update available: " <> version
    CheckFailed(reason) ->
      "Hermes BEAM v" <> current_version() <> " — check failed: " <> reason
  }
}

pub fn version_info() -> List(#(String, String)) {
  [
    #("version", current_version()),
    #("install_path", install_path()),
    #("auto_update", case auto_update_enabled() {
      True -> "enabled"
      False -> "disabled"
    }),
  ]
}
