import gleam/io
import uds_ffi

pub fn uds_listen_test() {
  let path = "/tmp/hermes_test.sock"
  let assert Ok(_listen_sock) = uds_ffi.listen_uds(path)
  io.println("Successfully listened on UDS")
}
