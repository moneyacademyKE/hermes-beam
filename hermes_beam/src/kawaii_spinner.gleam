import gleam/erlang/process.{type Selector, type Subject}
import gleam/io
import gleam/list

pub type SpinnerMessage {
  Stop
}

pub type SpinnerState {
  SpinnerState(frames: List(String), text: String, idx: Int)
}

pub fn start(text: String) -> Subject(SpinnerMessage) {
  let subj = process.new_subject()
  let frames = ["(>_<) ", "(^_^) ", "(-_-) ", "(O_O) "]

  process.spawn(fn() {
    let selector = process.new_selector() |> process.select(subj)
    loop(selector, SpinnerState(frames, text, 0))
  })

  subj
}

pub fn stop(subj: Subject(SpinnerMessage)) -> Nil {
  process.send(subj, Stop)
}

fn loop(selector: Selector(SpinnerMessage), state: SpinnerState) -> Nil {
  let msg_res = process.selector_receive(selector, 200)
  case msg_res {
    Ok(Stop) -> {
      io.print("\r\u{001b}[K")
      Nil
    }
    Error(_) -> {
      // Timeout occurred, advance frame
      let frame = get_frame(state.frames, state.idx)
      io.print("\r\u{001b}[K" <> frame <> state.text)

      let next_idx = case state.idx >= list.length(state.frames) - 1 {
        True -> 0
        False -> state.idx + 1
      }
      loop(selector, SpinnerState(..state, idx: next_idx))
    }
  }
}

fn get_frame(frames: List(String), idx: Int) -> String {
  case list.drop(frames, idx) {
    [f, ..] -> f
    [] -> ""
  }
}
