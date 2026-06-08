-module(uds_native).
-export([listen_uds/1, accept_uds/1, recv_uds/2, send_uds/2, close_uds/1]).

listen_uds(Path) ->
    file:delete(Path),
    case gen_tcp:listen(0, [{ifaddr, {local, binary_to_list(Path)}}, {packet, 0}, {active, false}, {mode, binary}]) of
        {ok, ListenSocket} -> {ok, ListenSocket};
        {error, Reason} -> {error, Reason}
    end.

accept_uds(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, Reason}
    end.

recv_uds(Socket, Length) ->
    gen_tcp:recv(Socket, Length).

send_uds(Socket, Data) ->
    gen_tcp:send(Socket, Data).

close_uds(Socket) ->
    gen_tcp:close(Socket).
