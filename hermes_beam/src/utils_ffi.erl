-module(utils_ffi).
-export([
    identity/1,
    read_link/1,
    rename/2,
    open_temp_file/1,
    write/2,
    sync/1,
    close/1,
    delete/1,
    unique_integer/0,
    putenv/2,
    format_float/1,
    read_line/1
]).

identity(X) -> X.

read_link(Path) ->
    case file:read_link(binary_to_list(Path)) of
        {ok, Target} -> {ok, list_to_binary(Target)};
        {error, Reason} -> {error, Reason}
    end.

rename(From, To) ->
    file:rename(binary_to_list(From), binary_to_list(To)).

open_temp_file(Path) ->
    file:open(binary_to_list(Path), [write, raw, binary, exclusive]).

write(Fd, Data) ->
    file:write(Fd, Data).

sync(Fd) ->
    file:sync(Fd).

close(Fd) ->
    file:close(Fd).

delete(Path) ->
    file:delete(binary_to_list(Path)).

unique_integer() ->
    erlang:unique_integer([positive]).

putenv(Key, Value) ->
    os:putenv(binary_to_list(Key), binary_to_list(Value)).

format_float(Val) ->
    List = io_lib:format("~.2f", [Val]),
    list_to_binary(List).

read_line(PromptBin) ->
    Prompt = binary_to_list(PromptBin),
    case io:get_line(Prompt) of
        eof -> {error, eof};
        {error, Reason} -> {error, Reason};
        Data when is_binary(Data) -> {ok, Data};
        Data -> {ok, list_to_binary(Data)}
    end.
