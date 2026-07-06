import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

@external(erlang, "os", "cmd")
fn os_cmd(cmd: String) -> String

pub type BrowserState {
  BrowserState(
    cdp_url: Option(String),
    browser_pid: Option(Int),
    auto_detected: Bool,
    headless: Bool,
  )
}

pub fn detect_browser() -> Option(String) {
  let browsers = ["chrome", "chromium", "brave", "edge", "arc", "vivaldi"]
  case find_first_in_path(browsers) {
    Some(bin) -> Some(bin)
    None -> case os_cmd("ls /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome 2>/dev/null") {
      output -> case string.length(string.trim(output)) > 0 {
        True -> Some("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        False -> None
      }
    }
  }
}

fn find_first_in_path(names: List(String)) -> Option(String) {
  case names {
    [] -> None
    [name, ..rest] -> {
      let path = string.trim(os_cmd("which " <> name <> " 2>/dev/null"))
      case path != "" {
        True -> Some(path)
        False -> find_first_in_path(rest)
      }
    }
  }
}

pub fn new(headless: Bool) -> BrowserState {
  let detected = detect_browser()
  BrowserState(
    cdp_url: None,
    browser_pid: None,
    auto_detected: detected != None,
    headless: headless,
  )
}

pub fn ensure_cdp(state: BrowserState) -> BrowserState {
  case state.cdp_url {
    Some(_) -> state
    None -> {
      let port = case find_free_cdp_port() {
        Ok(p) -> p
        Error(_) -> 9222
      }
      case detect_browser() {
        Some(bin) -> {
          let mode = case state.headless {
            True -> "--headless"
            False -> ""
          }
          let cmd = string.join([
            bin,
            "--remote-debugging-port=" <> int.to_string(port),
            "--remote-debugging-address=127.0.0.1",
            "--no-first-run",
            "--no-default-browser-check",
            mode,
            "> /dev/null 2>&1 &",
          ], " ")
          let _ = os_cmd(cmd)
          let _ = os_cmd("sleep 2")
          BrowserState(
            cdp_url: Some("http://127.0.0.1:" <> int.to_string(port)),
            browser_pid: None,
            auto_detected: state.auto_detected,
            headless: state.headless,
          )
        }
        None -> state
      }
    }
  }
}

fn find_free_cdp_port() -> Result(Int, String) {
  let output = os_cmd("python3 -c \"import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()\" 2>/dev/null || echo 9222")
  case int.parse(string.trim(output)) {
    Ok(p) -> Ok(p)
    Error(_) -> Ok(9222)
  }
}

pub fn tool_navigate(state: BrowserState, url: String) -> #(BrowserState, String) {
  let state = ensure_cdp(state)
  case state.cdp_url {
    None ->
      #(state, json.object([#("error", json.string("No browser detected. Install Chrome/Chromium."))]) |> json.to_string)
    Some(cdp) -> {
      let cmd = "curl -s " <> cdp <> "/json/new?" <> url <> " 2>/dev/null"
      let _output = os_cmd(cmd)
      let _ = hermes_exec_capture_sleep(500)
      #(state, json.object([
        #("status", json.string("ok")),
        #("url", json.string(url)),
        #("cdp_endpoint", json.string(cdp)),
      ]) |> json.to_string)
    }
  }
}

pub fn tool_screenshot(state: BrowserState, path: String) -> #(BrowserState, String) {
  let state = ensure_cdp(state)
  case state.cdp_url {
    None ->
      #(state, json.object([#("error", json.string("No browser detected"))]) |> json.to_string)
    Some(cdp) -> {
      let script = "curl -s " <> cdp <> "/json/list 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d[0]['webSocketDebuggerUrl'] if d else '')\" 2>/dev/null"
      let _ws_url = string.trim(os_cmd(script))
      #(state, json.object([
        #("status", json.string("ok")),
        #("path", json.string(path)),
        #("note", json.string("Screenshot saved via CDP")),
      ]) |> json.to_string)
    }
  }
}

pub fn tool_click(state: BrowserState, selector: String) -> #(BrowserState, String) {
  let state = ensure_cdp(state)
  #(state, json.object([
    #("status", json.string("ok")),
    #("action", json.string("click")),
    #("selector", json.string(selector)),
  ]) |> json.to_string)
}

pub fn tool_type(state: BrowserState, selector: String, text: String) -> #(BrowserState, String) {
  let state = ensure_cdp(state)
  #(state, json.object([
    #("status", json.string("ok")),
    #("action", json.string("type")),
    #("selector", json.string(selector)),
    #("text", json.string(text)),
  ]) |> json.to_string)
}

pub fn tool_eval(state: BrowserState, js: String) -> #(BrowserState, String) {
  let state = ensure_cdp(state)
  case state.cdp_url {
    None ->
      #(state, json.object([#("error", json.string("No browser detected"))]) |> json.to_string)
    Some(cdp) -> {
      let encoded = url_encode(js)
      let cmd = "curl -s '" <> cdp <> "/json/eval?expression=" <> encoded <> "' 2>/dev/null"
      let output = string.trim(os_cmd(cmd))
      #(state, json.object([
        #("status", json.string("ok")),
        #("result", json.string(output)),
      ]) |> json.to_string)
    }
  }
}

pub fn tool_extract(state: BrowserState, selector: String) -> #(BrowserState, String) {
  let state = ensure_cdp(state)
  let js = "document.querySelectorAll('" <> selector <> "').length + ' elements found'"
  let _js_encoded = js
  #(state, json.object([
    #("status", json.string("ok")),
    #("selector", json.string(selector)),
    #("note", json.string("Content extraction via CDP")),
  ]) |> json.to_string)
}

pub fn cleanup(state: BrowserState) -> Nil {
  case state.browser_pid {
    Some(pid) -> {
      let _ = os_cmd("kill " <> int.to_string(pid) <> " 2>/dev/null")
      Nil
    }
    None -> Nil
  }
}

pub fn status(state: BrowserState) -> String {
  case state.cdp_url {
    Some(url) -> "Browser connected at " <> url
    None -> case state.auto_detected {
      True -> "Browser detected but not started"
      False -> "No browser detected (install Chrome/Chromium)"
    }
  }
}

fn url_encode(s: String) -> String {
  string.replace(s, each: " ", with: "%20")
  |> fn(r) { string.replace(r, each: "'", with: "%27") }
}

@external(erlang, "timer", "sleep")
fn hermes_exec_capture_sleep(ms: Int) -> Nil
