import gleam/erlang/process
import gleam/io
import gleam/int
import mist
import simplifile
import wisp
import wisp/wisp_mist
import constants
import utils

pub fn handle_request(req: wisp.Request, dist_path: String) -> wisp.Response {
  // Apply Wisp's base middleware for logging and crash recovery
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  // Try serving files statically from the build output directory
  use <- wisp.serve_static(req, under: "/", from: dist_path)

  // SPA fallback routing: serve index.html for any other URL path
  let index_path = constants.path_join(dist_path, "index.html")
  case simplifile.read(index_path) {
    Ok(html) -> {
      wisp.ok()
      |> wisp.html_body(html)
    }
    Error(_) -> {
      wisp.not_found()
      |> wisp.html_body("SPA Entry index.html not found")
    }
  }
}

pub fn start(port: Int) -> Result(Nil, Nil) {
  // Configure Wisp's logger
  wisp.configure_logger()

  // Resolve absolute path to jack-portfolio/dist
  let assert Ok(cwd) = utils.get_cwd()
  let dist_path = constants.path_join(cwd, "../jack-portfolio/dist")

  io.println("══════════════════════════════════════════════════")
  io.println("  Hermes Portfolio Server — Native Mist + Wisp    ")
  io.println("══════════════════════════════════════════════════")
  io.println("  Serving Assets From : " <> dist_path)
  io.println("  Binding Address     : http://0.0.0.0:" <> int.to_string(port) <> "/")
  io.println("══════════════════════════════════════════════════")

  // Generate a random session signing key
  let secret_key_base = wisp.random_string(64)

  // Build request handler closure closing over the dist path
  let handler = handle_request(_, dist_path)

  // Bind Mist to HTTP port
  let assert Ok(_) =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(port)
    |> mist.start

  // Run OTP process loop forever
  process.sleep_forever()

  Ok(Nil)
}
