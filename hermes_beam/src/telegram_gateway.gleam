import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type State {
  State(token: String, offset: Int, run_agent: fn(String, String) -> String)
}

pub type TelegramMessage {
  TelegramMessage(chat_id: Int, text: String)
}

pub type TelegramUpdate {
  TelegramUpdate(update_id: Int, message: TelegramMessage)
}

@external(erlang, "timer", "sleep")
pub fn sleep_ms(ms: Int) -> Nil

@external(erlang, "hermes_http", "fetch")
pub fn get_request(url: String) -> Result(String, Dynamic)

@external(erlang, "hermes_http", "post")
pub fn post_request(
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: String,
) -> Result(String, Dynamic)

pub fn send_typing(token: String, chat_id: Int) -> Nil {
  let url = "https://api.telegram.org/bot" <> token <> "/sendChatAction"
  let body =
    "{\"chat_id\": " <> int.to_string(chat_id) <> ", \"action\": \"typing\"}"
  let _ =
    post_request(
      url,
      [#("Content-Type", "application/json")],
      "application/json",
      body,
    )
  Nil
}

pub fn start(
  token: String,
  run_agent: fn(String, String) -> String,
) -> process.Pid {
  process.spawn(fn() {
    poll_loop(State(token: token, offset: 0, run_agent: run_agent))
  })
}

fn poll_loop(state: State) -> Nil {
  let url =
    "https://api.telegram.org/bot"
    <> state.token
    <> "/getUpdates?offset="
    <> int.to_string(state.offset)
    <> "&timeout=10"

  case get_request(url) {
    Ok(json_body) -> {
      let #(next_offset, messages) = parse_telegram_updates(json_body)

      // Route each message in a separate BEAM process (actor) to avoid blocking the polling loop
      list.each(messages, fn(msg) {
        process.spawn(fn() {
          send_typing(state.token, msg.chat_id)
          let session_id = "tg_" <> int.to_string(msg.chat_id)
          let reply = state.run_agent(msg.text, session_id)
          let send_url =
            "https://api.telegram.org/bot" <> state.token <> "/sendMessage"

          // Basic JSON escaping for strings
          let escaped_reply = string.replace(reply, "\"", "\\\"")
          let escaped_reply = string.replace(escaped_reply, "\n", "\\n")

          let body =
            "{\"chat_id\": "
            <> int.to_string(msg.chat_id)
            <> ", \"text\": \""
            <> escaped_reply
            <> "\"}"
          let _ =
            post_request(
              send_url,
              [#("Content-Type", "application/json")],
              "application/json",
              body,
            )
          Nil
        })
      })

      let next_offset = case next_offset {
        Some(o) -> o + 1
        None -> state.offset
      }

      sleep_ms(1000)
      poll_loop(State(..state, offset: next_offset))
    }
    Error(_) -> {
      sleep_ms(5000)
      poll_loop(state)
    }
  }
}

fn decode_single_update(dyn: Dynamic) -> Result(TelegramUpdate, Nil) {
  let message_decoder = {
    use chat_id <- decode.field("chat", {
      use id <- decode.field("id", decode.int)
      decode.success(id)
    })
    use text <- decode.field("text", decode.string)
    decode.success(TelegramMessage(chat_id: chat_id, text: text))
  }
  let update_decoder = {
    use update_id <- decode.field("update_id", decode.int)
    use message <- decode.field("message", message_decoder)
    decode.success(TelegramUpdate(update_id: update_id, message: message))
  }

  case decode.run(dyn, update_decoder) {
    Ok(up) -> Ok(up)
    Error(_) -> Error(Nil)
  }
}

pub fn parse_telegram_updates(
  json_str: String,
) -> #(Option(Int), List(TelegramMessage)) {
  let raw_response_decoder = {
    use ok <- decode.field("ok", decode.bool)
    use result <- decode.field("result", decode.list(decode.dynamic))
    decode.success(#(ok, result))
  }

  case json.parse(from: json_str, using: raw_response_decoder) {
    Ok(#(True, raw_updates)) -> {
      let updates = list.filter_map(raw_updates, decode_single_update)
      let max_id =
        list.fold(updates, None, fn(acc, update) {
          case acc {
            Some(curr) if curr > update.update_id -> Some(curr)
            _ -> Some(update.update_id)
          }
        })
      let msgs = list.map(updates, fn(u) { u.message })
      #(max_id, msgs)
    }
    _ -> #(None, [])
  }
}
