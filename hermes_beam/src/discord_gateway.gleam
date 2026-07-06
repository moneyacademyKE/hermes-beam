import constants
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import hermes_agent
import hermes_exec
import state_actor.{type StateActor}

@external(erlang, "hermes_http", "post_with_retry")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: String,
) -> Result(String, String)

@external(erlang, "hermes_http", "fetch_with_headers")
fn http_get(
  url: String,
  headers: List(#(String, String)),
) -> Result(String, String)

@external(erlang, "timer", "sleep")
fn timer_sleep(ms: Int) -> Nil

pub type DiscordConfig {
  DiscordConfig(
    token: String,
    allowed_users: List(String),
    allowed_channels: List(String),
    respond_to: String,
    prefix: String,
  )
}

pub fn config_from_env() -> Option(DiscordConfig) {
  case constants.get_env("HERMES_DISCORD_TOKEN") {
    None -> None
    Some(token) -> {
      case token == "" {
        True -> None
        False -> {
          let allowed_users = parse_list_env("HERMES_DISCORD_ALLOWED_USERS")
          let allowed_channels = parse_list_env("HERMES_DISCORD_ALLOWED_CHANNELS")
          let respond_to = case constants.get_env("HERMES_DISCORD_RESPOND_TO") {
            Some(v) -> v
            None -> "mention"
          }
          let prefix = case constants.get_env("HERMES_DISCORD_PREFIX") {
            Some(v) -> v
            None -> "!"
          }
          Some(DiscordConfig(
            token: token,
            allowed_users: allowed_users,
            allowed_channels: allowed_channels,
            respond_to: respond_to,
            prefix: prefix,
          ))
        }
      }
    }
  }
}

fn parse_list_env(name: String) -> List(String) {
  case constants.get_env(name) {
    Some(val) ->
      val
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(s) { s != "" })
    None -> []
  }
}

fn api_base() -> String {
  "https://discord.com/api/v10"
}

fn auth_headers(token: String) -> List(#(String, String)) {
  [
    #("Authorization", "Bot " <> token),
    #("Content-Type", "application/json"),
  ]
}

pub fn send_message(
  config: DiscordConfig,
  channel_id: String,
  content: String,
) -> Result(String, String) {
  let url = api_base() <> "/channels/" <> channel_id <> "/messages"
  let body =
    json.object([#("content", json.string(content))])
    |> json.to_string
  http_post(url, auth_headers(config.token), "application/json", body)
}

pub fn start_gateway(
  db_conn: StateActor,
  api_key: String,
  base_url: String,
  model: String,
  config: DiscordConfig,
) -> Nil {
  io.println("══════════════════════════════════════════════════")
  io.println("  Hermes BEAM — Discord Gateway")
  io.println("══════════════════════════════════════════════════")

  case get_bot_user(config) {
    Ok(bot_id) -> {
      io.println("Bot connected. ID: " <> bot_id)
      poll_loop(db_conn, api_key, base_url, model, config, bot_id, "?")
    }
    Error(err) -> {
      io.println("Failed to connect Discord bot: " <> err)
      io.println("Check HERMES_DISCORD_TOKEN is set correctly.")
      Nil
    }
  }
}

fn get_bot_user(config: DiscordConfig) -> Result(String, String) {
  case http_get(api_base() <> "/users/@me", auth_headers(config.token)) {
    Ok(body) -> {
      let decoder = decode.field("id", decode.string, decode.success)
      case json.parse(from: body, using: decoder) {
        Ok(id) -> Ok(id)
        Error(_) -> Error("Failed to parse bot user response")
      }
    }
    Error(err) -> Error(err)
  }
}

fn poll_loop(
  db_conn: StateActor,
  api_key: String,
  base_url: String,
  model: String,
  config: DiscordConfig,
  bot_id: String,
  last_message_id: String,
) -> Nil {
  timer_sleep(2000)

  let url = case last_message_id {
    "?" -> api_base() <> "/users/@me/guilds"
    _ -> api_base() <> "/channels/" <> "?limit=10&after=" <> last_message_id
  }

  case get_channels(config) {
    Ok(channels) -> {
      let _ = list.each(channels, fn(ch) {
        case fetch_recent_messages(config, ch, last_message_id) {
          Ok(messages) ->
            list.each(messages, fn(msg) {
              case should_respond(config, bot_id, msg) {
                True ->
                  handle_discord_message(
                    db_conn,
                    api_key,
                    base_url,
                    model,
                    config,
                    msg,
                  )
                False -> Nil
              }
            })
          Error(_) -> Nil
        }
      })
    }
    Error(_) -> Nil
  }

  poll_loop(db_conn, api_key, base_url, model, config, bot_id, last_message_id)
}

fn get_channels(config: DiscordConfig) -> Result(List(String), String) {
  case constants.get_env("HERMES_DISCORD_CHANNEL_IDS") {
    Some(val) -> {
      let ids =
        val
        |> string.split(",")
        |> list.map(string.trim)
        |> list.filter(fn(s) { s != "" })
      Ok(ids)
    }
    None -> Ok([])
  }
}

fn fetch_recent_messages(
  config: DiscordConfig,
  channel_id: String,
  after: String,
) -> Result(List(DiscordMessage), String) {
  let url = case after {
    "?" ->
      api_base() <> "/channels/" <> channel_id <> "/messages?limit=5"
    _ ->
      api_base() <> "/channels/" <> channel_id <> "/messages?limit=5&after=" <> after
  }
  case http_get(url, auth_headers(config.token)) {
    Ok(body) -> parse_messages(body, channel_id)
    Error(err) -> Error(err)
  }
}

type DiscordMessage {
  DiscordMessage(
    id: String,
    channel_id: String,
    author_id: String,
    content: String,
    mentions_bot: Bool,
  )
}

fn parse_messages(
  body: String,
  channel_id: String,
) -> Result(List(DiscordMessage), String) {
  let decoder =
    decode.list({
      use id <- decode.field("id", decode.string)
      use author <- decode.field("author", {
        use aid <- decode.field("id", decode.string)
        decode.success(aid)
      })
      use content <- decode.field("content", decode.string)
      use mentions <- decode.optional_field(
        "mentions",
        [],
        decode.list({
          use mid <- decode.field("id", decode.string)
          decode.success(mid)
        }),
      )
      decode.success(DiscordMessage(
        id: id,
        channel_id: channel_id,
        author_id: author,
        content: content,
        mentions_bot: list.contains(mentions, author),
      ))
    })
  case json.parse(from: body, using: decoder) {
    Ok(msgs) -> Ok(msgs)
    Error(_) -> Ok([])
  }
}

fn should_respond(
  config: DiscordConfig,
  bot_id: String,
  msg: DiscordMessage,
) -> Bool {
  case msg.author_id == bot_id {
    True -> False
    False -> {
      case config.allowed_channels {
        [] -> True
        channels -> list.contains(channels, msg.channel_id)
      }
    }
  }
}

fn handle_discord_message(
  db_conn: StateActor,
  api_key: String,
  base_url: String,
  model: String,
  config: DiscordConfig,
  msg: DiscordMessage,
) -> Nil {
  io.println("[Discord] Message from " <> msg.author_id <> ": " <> msg.content)

  let session_id = "discord_" <> msg.channel_id
  let cwd = hermes_exec.get_temp_dir()
  let exec_env = hermes_exec.new_terminal_env(cwd, 120_000, [])

  let agent_res =
    hermes_agent.new_agent_state(
      session_id,
      model,
      cwd,
      db_conn,
      exec_env,
      api_key,
      base_url,
      "You are Hermes, a Discord bot. Respond concisely.",
      10,
      None,
      None,
      None,
    )

  case agent_res {
    Ok(agent) ->
      case hermes_agent.run_conversation(agent, msg.content) {
        Ok(new_state) -> {
          let response = case list.first(new_state.history) {
            Ok(history_msg) -> extract_content(history_msg)
            Error(_) -> "Error: no response generated"
          }
          let truncated = case string.length(response) > 1900 {
            True -> string.slice(response, 0, 1900) <> "...(truncated)"
            False -> response
          }
          let _ = send_message(config, msg.channel_id, truncated)
          Nil
        }
        Error(err) -> {
          let _ = send_message(config, msg.channel_id, "Error: " <> err)
          Nil
        }
      }
    Error(err) -> {
      io.println("[Discord] Agent init failed: " <> err)
      Nil
    }
  }
}

fn extract_content(msg: String) -> String {
  let decoder = decode.field("content", decode.string, decode.success)
  case json.parse(from: msg, using: decoder) {
    Ok(content) -> content
    Error(_) -> msg
  }
}
