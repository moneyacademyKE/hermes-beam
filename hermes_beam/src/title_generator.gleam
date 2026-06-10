import constants
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import hermes_agent
import hermes_client
import state_actor

pub fn generate_and_save(
  session_id: String,
  user_prompt: String,
  agent_response: String,
  api_key: String,
  base_url: String,
  db_conn: state_actor.StateActor,
) -> Nil {
  // Start an unlinked process so it doesn't crash the REPL if it fails
  let _ =
    process.spawn(fn() {
      let model = case constants.get_env("HERMES_MODEL") {
        Some(m) -> m
        None -> "openai/gpt-4o-mini"
      }
      let sys_prompt =
        "Generate a concise 3-5 word title for the following conversation. ONLY output the title, no quotes or prefix."

      let history = [
        hermes_agent.user_message(user_prompt),
        hermes_agent.assistant_message(agent_response),
      ]

      let body =
        hermes_agent.build_request_body(
          model,
          sys_prompt,
          history,
          "[]",
          False,
          "",
        )

      let headers = [
        #("Authorization", "Bearer " <> api_key),
        #("Content-Type", "application/json"),
      ]

      case
        hermes_client.post_request_with_retry(
          base_url <> "/chat/completions",
          headers,
          "application/json",
          body,
        )
      {
        Ok(resp_json) -> {
          case hermes_agent.parse_completion_response(resp_json) {
            hermes_agent.FinalText(text) -> {
              let clean_title = text |> string.replace("\"", "") |> string.trim
              let _ =
                state_actor.update_session_title(
                  db_conn,
                  session_id,
                  clean_title,
                )
              Nil
            }
            _ -> Nil
          }
        }
        Error(_) -> Nil
      }
    })
  Nil
}
