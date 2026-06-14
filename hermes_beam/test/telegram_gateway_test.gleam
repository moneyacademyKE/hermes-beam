import telegram_gateway
import gleam/option.{None, Some}
import hermes_beam
import taskle
import telega/client
import telega/bot
import telega/internal/config
import telega/model/types
import telega/update
import gleam/http/response
import gleam/erlang/process

@external(erlang, "hermes_http", "identity")
pub fn unsafe_coerce(x: x) -> y

pub fn parse_telegram_updates_test() {
  let mock_json = "
    {
      \"ok\": true,
      \"result\": [
        {
          \"update_id\": 42,
          \"message\": {
            \"message_id\": 1,
            \"date\": 1700000000,
            \"chat\": {
              \"id\": 1001,
              \"type\": \"private\"
            },
            \"text\": \"Hello bot\"
          }
        }
      ]
    }
  "

  let #(max_id, messages) = telegram_gateway.parse_telegram_updates(mock_json)

  let assert Some(42) = max_id
  let assert [telegram_gateway.TelegramMessage(chat_id: 1001, text: "Hello bot")] = messages
}

pub fn port_lock_test() {
  // Try to acquire lock on an arbitrary high port
  let assert Ok(socket1) = hermes_beam.acquire_port_lock(18_555)

  // Trying to lock the same port again should return an error
  let assert Error(_) = hermes_beam.acquire_port_lock(18_555)

  // Releasing the lock should allow it to be locked again
  hermes_beam.release_port_lock(socket1)
  let assert Ok(socket2) = hermes_beam.acquire_port_lock(18_555)
  hermes_beam.release_port_lock(socket2)
}

pub fn taskle_async_success_test() {
  let task = taskle.async(fn() {
    10 + 20
  })

  let assert Ok(30) = taskle.await(task, 1000)
}

pub fn taskle_async_timeout_test() {
  let task = taskle.async(fn() {
    telegram_gateway.sleep_ms(100)
    42
  })

  // Awaiting with less than 100ms should timeout
  let assert Error(taskle.Timeout) = taskle.await(task, 10)
}

pub fn taskle_async_crash_test() {
  let task = taskle.async(fn() {
    // Force a crash
    let assert Ok(2) = int_parse_error()
    2
  })

  let assert Error(taskle.Crashed(_)) = taskle.await(task, 1000)
}

fn int_parse_error() -> Result(Int, Nil) {
  Error(Nil)
}

pub fn router_handler_test() {
  let mock_client = client.new("test_token", fn(_req) {
    Ok(response.Response(status: 200, headers: [], body: "{}"))
  })

  let dummy_config =
    config.Config(
      server_url: "https://api.telegram.org",
      webhook_path: "webhook",
      secret_token: "secret",
      api_client: mock_client,
    )

  let dummy_user =
    types.User(
      id: 12_345,
      is_bot: True,
      first_name: "test_bot",
      last_name: None,
      username: Some("test_bot"),
      language_code: None,
      is_premium: None,
      added_to_attachment_menu: None,
      can_join_groups: None,
      can_read_all_group_messages: None,
      supports_inline_queries: None,
      can_connect_to_business: None,
      has_main_web_app: None,
      has_topics_enabled: None,
      allows_users_to_create_topics: None,
      can_manage_bots: None,
      supports_guest_queries: None,
    )

  let dummy_update: update.Update = unsafe_coerce(Nil)

  let ctx =
    bot.Context(
      key: "1001",
      update: dummy_update,
      config: dummy_config,
      session: Nil,
      chat_subject: process.new_subject(),
      start_time: None,
      log_prefix: None,
      bot_info: dummy_user,
    )

  let mock_agent = fn(text, session_id) {
    let assert "Hello bot" = text
    let assert "tg_1001" = session_id
    "Hello user!"
  }

  let handler = telegram_gateway.make_text_handler(mock_agent)

  let assert Ok(res_ctx) = handler(ctx, "Hello bot")
  let assert "1001" = res_ctx.key
}
