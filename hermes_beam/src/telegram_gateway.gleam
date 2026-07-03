import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import constants
import taskle
import telega
import telega/api
import telega/bot
import telega/client
import telega/error.{type TelegaError, FetchError}
import telega/model/decoder
import telega/model/types
import telega/reply
import telega/router
import telega/update

pub type TelegramMessage {
  TelegramMessage(chat_id: Int, text: String)
}

pub type TelegramAccessPolicy {
  TelegramAccessPolicy(allowed_users: List(String), allowed_chats: List(String))
}

pub fn parse_allowlist(value: String) -> List(String) {
  value
  |> string.split(on: ",")
  |> list.map(string.trim)
  |> list.filter(fn(item) { item != "" })
}

pub fn access_policy_from_env() -> TelegramAccessPolicy {
  let allowed_users = case constants.get_env("HERMES_TELEGRAM_ALLOWED_USERS") {
    Some(value) -> parse_allowlist(value)
    None -> case constants.get_env("TELEGRAM_ALLOWED_USERS") {
      Some(value) -> parse_allowlist(value)
      None -> case constants.get_env("GATEWAY_ALLOWED_USERS") {
        Some(value) -> parse_allowlist(value)
        None -> []
      }
    }
  }
  let allowed_chats = case constants.get_env("HERMES_TELEGRAM_ALLOWED_CHATS") {
    Some(value) -> parse_allowlist(value)
    None -> case constants.get_env("TELEGRAM_ALLOWED_CHATS") {
      Some(value) -> parse_allowlist(value)
      None -> []
    }
  }
  TelegramAccessPolicy(allowed_users: allowed_users, allowed_chats: allowed_chats)
}

pub fn is_allowed_chat(policy: TelegramAccessPolicy, chat_id: String) -> Bool {
  case policy.allowed_chats {
    [] -> True
    allowed -> list.contains(allowed, chat_id)
  }
}

pub fn is_allowed_user(policy: TelegramAccessPolicy, user_id: String) -> Bool {
  case policy.allowed_users {
    [] -> True
    allowed -> list.contains(allowed, user_id)
  }
}

pub fn is_allowed(
  policy: TelegramAccessPolicy,
  chat_id: String,
  user_id: Option(String),
) -> Bool {
  let chat_allowed = is_allowed_chat(policy, chat_id)
  let user_allowed = case policy.allowed_users, user_id {
    [], _ -> True
    _, Some(id) -> is_allowed_user(policy, id)
    _, None -> False
  }
  chat_allowed && user_allowed
}

pub fn user_id_from_update(raw_update: update.Update) -> Option(String) {
  case raw_update {
    update.TextUpdate(from_id, _, _, _, _) -> Some(int.to_string(from_id))
    update.CommandUpdate(from_id, _, _, _, _) -> Some(int.to_string(from_id))
    _ -> None
  }
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

pub fn http_fetch_client(
  req: Request(String),
) -> Result(Response(String), TelegaError) {
  let url = request.to_uri(req) |> uri.to_string

  case req.method {
    http.Get -> {
      case get_request(url) {
        Ok(body) -> Ok(Response(status: 200, headers: [], body: body))
        Error(err) -> Error(FetchError(string.inspect(err)))
      }
    }
    http.Post -> {
      let content_type =
        list.find(req.headers, fn(h) { string.lowercase(h.0) == "content-type" })
        |> result.map(fn(h) { h.1 })
        |> result.unwrap("application/json")

      case post_request(url, req.headers, content_type, req.body) {
        Ok(body) -> Ok(Response(status: 200, headers: [], body: body))
        Error(err) -> Error(FetchError(string.inspect(err)))
      }
    }
    _ -> Error(FetchError("Unsupported method: " <> string.inspect(req.method)))
  }
}

pub fn send_typing(cl: client.TelegramClient, chat_id: String) -> Nil {
  let params =
    types.SendChatActionParameters(
      chat_id: types.Str(chat_id),
      business_connection_id: None,
      message_thread_id: None,
      action: types.Typing,
    )
  let _ = api.send_chat_action(client: cl, parameters: params)
  Nil
}

pub fn make_text_handler(
  run_agent: fn(String, String) -> String,
) -> fn(
  bot.Context(Nil, error.TelegaError),
  String,
) -> Result(bot.Context(Nil, error.TelegaError), error.TelegaError) {
  make_text_handler_with_policy(run_agent, access_policy_from_env())
}

pub fn make_text_handler_with_policy(
  run_agent: fn(String, String) -> String,
  policy: TelegramAccessPolicy,
) -> fn(
  bot.Context(Nil, error.TelegaError),
  String,
) -> Result(bot.Context(Nil, error.TelegaError), error.TelegaError) {
  fn(ctx: bot.Context(Nil, error.TelegaError), text: String) {
    let session_id = "tg_" <> ctx.key

    let user_id = case policy.allowed_users {
      [] -> None
      _ -> user_id_from_update(ctx.update)
    }

    case is_allowed(policy, ctx.key, user_id) {
      False -> {
        io.println("Telegram message rejected by allowlist for chat_id: " <> ctx.key)
        Ok(ctx)
      }
      True -> {
        let task =
          taskle.async(fn() {
            send_typing(ctx.config.api_client, ctx.key)
            let reply_str = run_agent(text, session_id)
            let _ = reply.with_text(ctx, reply_str)
            Nil
          })

        // Sequential wait per chat with 3 min timeout
        case taskle.await(task, 180_000) {
          Ok(Nil) -> Ok(ctx)
          Error(taskle.Timeout) -> {
            let _ = taskle.cancel(task)
            let _ =
              io.println(
                "Telegram task timed out after 3 minutes for chat_id: " <> ctx.key,
              )
            let _ = reply.with_text(ctx, "Request timed out. Please try again.")
            Ok(ctx)
          }
          Error(taskle.Crashed(reason)) -> {
            let _ =
              io.println(
                "Telegram task crashed: " <> reason <> " for chat_id: " <> ctx.key,
              )
            let _ =
              reply.with_text(ctx, "An internal error occurred. Please try again.")
            Ok(ctx)
          }
          Error(_) -> {
            let _ =
              reply.with_text(
                ctx,
                "An internal task error occurred. Please try again.",
              )
            Ok(ctx)
          }
        }
      }
    }
  }
}

/// Starts the Telegram gateway listener.
///
/// CRITICAL: Starts the telega supervised bot and long poller.
/// Webhooks are cleared automatically. Backfill is active (polling starts at offset 0).
pub fn start(
  token: String,
  run_agent: fn(String, String) -> String,
) -> process.Pid {
  let api_client = client.new(token, http_fetch_client)

  let r =
    router.new("hermes_router")
    |> router.on_any_text(make_text_handler(run_agent))

  let assert Ok(bot) =
    telega.new_for_polling(api_client)
    |> telega.with_router(r)
    |> telega.init_for_polling_nil_session()

  telega.get_supervisor_pid(bot)
}

pub fn parse_telegram_updates(
  json_str: String,
) -> #(Option(Int), List(TelegramMessage)) {
  let raw_response_decoder = {
    use ok <- decode.field("ok", decode.bool)
    use result <- decode.field("result", decode.list(decoder.update_decoder()))
    decode.success(#(ok, result))
  }

  case json.parse(from: json_str, using: raw_response_decoder) {
    Ok(#(True, updates)) -> {
      let max_id =
        list.fold(updates, None, fn(acc, update) {
          case acc {
            Some(curr) if curr > update.update_id -> Some(curr)
            _ -> Some(update.update_id)
          }
        })
      let msgs =
        list.filter_map(updates, fn(u) {
          case u.message {
            Some(m) -> {
              case m.text {
                Some(t) -> Ok(TelegramMessage(chat_id: m.chat.id, text: t))
                None -> Error(Nil)
              }
            }
            None -> Error(Nil)
          }
        })
      #(max_id, msgs)
    }
    _ -> #(None, [])
  }
}
