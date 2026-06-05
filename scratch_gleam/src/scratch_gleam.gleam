import gleam/io
import gleam/string

@external(erlang, "time_ffi", "read_link")
pub fn read_link(path: String) -> Result(String, Nil)

pub fn main() -> Nil {
  case read_link("/etc/localtime") {
    Ok(target) -> {
      io.println("Link target: " <> target)
      case string.split_once(target, on: "/zoneinfo/") {
        Ok(#(_, name)) -> io.println("Timezone: " <> name)
        Error(_) -> io.println("Could not parse timezone from target")
      }
    }
    Error(_) -> io.println("Error reading link")
  }
  Nil
}
