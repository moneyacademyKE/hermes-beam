import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import hermes_logger

pub type DiscordMessage {
  Connect
  Shutdown
}

pub type DiscordState {
  DiscordState(token: String, session_id: String)
}

pub opaque type DiscordActor {
  DiscordActor(subject: Subject(DiscordMessage))
}

pub fn start(token: String) -> Result(DiscordActor, actor.StartError) {
  let session_id = "discord_stub"
  hermes_logger.info(session_id, "Starting Discord Gateway process")

  actor.new(DiscordState(token, session_id))
  |> actor.on_message(loop)
  |> actor.start
  |> result.map(fn(started) { DiscordActor(started.data) })
}

fn loop(
  state: DiscordState,
  msg: DiscordMessage,
) -> actor.Next(DiscordState, DiscordMessage) {
  case msg {
    Connect -> {
      hermes_logger.info(
        state.session_id,
        "Connecting to wss://gateway.discord.gg (Stubbed)",
      )
      actor.continue(state)
    }
    Shutdown -> {
      hermes_logger.info(state.session_id, "Shutting down Discord Gateway")
      actor.stop()
    }
  }
}
