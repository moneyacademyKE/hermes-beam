import gleam/dynamic

pub type ListenSocket

pub type Socket

@external(erlang, "uds_native", "listen_uds")
pub fn listen_uds(path: String) -> Result(ListenSocket, dynamic.Dynamic)

@external(erlang, "uds_native", "accept_uds")
pub fn accept_uds(socket: ListenSocket) -> Result(Socket, dynamic.Dynamic)

@external(erlang, "uds_native", "recv_uds")
pub fn recv_uds(
  socket: Socket,
  length: Int,
) -> Result(BitArray, dynamic.Dynamic)

@external(erlang, "uds_native", "send_uds")
pub fn send_uds(socket: Socket, data: BitArray) -> Result(Nil, dynamic.Dynamic)

@external(erlang, "uds_native", "close_uds")
pub fn close_uds(socket: Socket) -> Result(Nil, dynamic.Dynamic)
