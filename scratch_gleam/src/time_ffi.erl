-module(time_ffi).
-export([os_cmd/1, read_link/1, whereis_cache/0, register_cache/1, send_to_cache_pid/2, get_env/1, os_family/0]).

os_cmd(CmdBinary) ->
    CmdList = binary_to_list(CmdBinary),
    ResultList = os:cmd(CmdList),
    list_to_binary(ResultList).

read_link(PathBinary) ->
    PathList = binary_to_list(PathBinary),
    case file:read_link(PathList) of
        {ok, TargetList} -> {ok, list_to_binary(TargetList)};
        {error, Reason} -> {error, Reason}
    end.

whereis_cache() ->
    case erlang:whereis(hermes_timezone_cache) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

register_cache(Pid) ->
    try
        erlang:register(hermes_timezone_cache, Pid),
        {ok, nil}
    catch
        _:_ -> {error, nil}
    end.

send_to_cache_pid(Pid, Msg) ->
    Pid ! Msg,
    nil.

get_env(NameBinary) ->
    NameList = binary_to_list(NameBinary),
    case os:getenv(NameList) of
        false -> {error, nil};
        ValList -> {ok, list_to_binary(ValList)}
    end.

os_family() ->
    case os:type() of
        {unix, darwin} -> darwin;
        {unix, linux} -> linux;
        {win32, nt} -> windows_nt;
        _ -> other
    end.
