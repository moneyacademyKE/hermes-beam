-module(hermes_exec_ffi).
-export([spawn_port/1, spawn_port_with_env/2, send_input/2, close_port/1, decode_port_message/1, kill_port_process/1, generate_uuid/0, get_all_env/0]).

spawn_port(CmdBin) ->
    Cmd = binary_to_list(CmdBin),
    try
        Port = erlang:open_port({spawn, Cmd}, [binary, exit_status, stream, use_stdio]),
        {ok, Port}
    catch
        _:Reason ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

spawn_port_with_env(CmdBin, EnvList) ->
    Cmd = binary_to_list(CmdBin),
    ErlEnv = [
        {binary_to_list(K), binary_to_list(V)}
        || {K, V} <- EnvList
    ],
    try
        Port = erlang:open_port({spawn, Cmd}, [binary, exit_status, stream, use_stdio, {env, ErlEnv}]),
        {ok, Port}
    catch
        _:Reason ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

send_input(Port, InputBin) ->
    try
        erlang:port_command(Port, InputBin),
        ok
    catch
        _:_ -> {error, closed}
    end.

close_port(Port) ->
    try
        erlang:port_close(Port),
        ok
    catch
        _:_ -> ok
    end.

decode_port_message(Msg) ->
    case Msg of
        {Port, {data, Data}} when is_port(Port) ->
            {port_data, Data};
        {Port, {exit_status, Status}} when is_port(Port) ->
            {port_exit, Status};
        _ ->
            port_ignored
    end.

kill_port_process(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} ->
            case os:type() of
                {unix, _} ->
                    os:cmd(io_lib:format("pkill -15 -P ~p; kill -15 ~p", [Pid, Pid])),
                    timer:sleep(50),
                    os:cmd(io_lib:format("pkill -9 -P ~p; kill -9 ~p", [Pid, Pid])),
                    ok;
                {win32, _} ->
                    os:cmd(io_lib:format("taskkill /F /T /PID ~p", [Pid])),
                    ok;
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

generate_uuid() ->
    Bytes = crypto:strong_rand_bytes(6),
    Hex = lists:flatten([io_lib:format("~2.16.0b", [B]) || B <- binary_to_list(Bytes)]),
    list_to_binary(Hex).

get_all_env() ->
    EnvList = os:getenv(),
    [
        parse_env_item(Item)
        || Item <- EnvList
    ].

parse_env_item(Item) ->
    case lists:splitwith(fun(C) -> C /= $= end, Item) of
        {Key, [$= | Value]} ->
            {list_to_binary(Key), list_to_binary(Value)};
        {Key, []} ->
            {list_to_binary(Key), <<>>}
    end.
