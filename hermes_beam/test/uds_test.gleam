
import uds_ffi
import gleam/io

pub fn uds_listen_test() {
  let path = "/tmp/hermes_test.sock"
  let assert Ok(listen_sock) = uds_ffi.listen_uds(path)
  io.println("Successfully listened on UDS")
}
