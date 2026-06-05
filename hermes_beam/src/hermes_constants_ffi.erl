-module(hermes_constants_ffi).
-export([
    is_windows/0,
    get_user_home/0,
    get_env/1,
    set_env/2,
    change_mode/2,
    get_home_override/0,
    set_home_override/1,
    erase_home_override/0,
    get_fallback_warned/0,
    set_fallback_warned/0,
    get_packaged_data_dir/1,
    write_stderr/1,
    apply_ipv4_preference/1,
    resolve_path/1,
    is_wsl/0,
    is_container/0
]).

is_windows() ->
    case os:type() of
        {win32, _} -> true;
        _ -> false
    end.

get_user_home() ->
    case init:get_argument(home) of
        {ok, [[Home]]} -> list_to_binary(Home);
        _ ->
            case os:getenv("HOME") of
                false ->
                    case os:getenv("USERPROFILE") of
                        false -> <<"/">>;
                        Val -> list_to_binary(Val)
                    end;
                Val -> list_to_binary(Val)
            end
    end.

get_env(Key) ->
    case os:getenv(binary_to_list(Key)) of
        false -> {error, nil};
        Val -> {ok, list_to_binary(Val)}
    end.

set_env(Key, Val) ->
    os:putenv(binary_to_list(Key), binary_to_list(Val)),
    ok.

change_mode(Path, Mode) ->
    case file:change_mode(binary_to_list(Path), Mode) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

get_home_override() ->
    case erlang:get(hermes_home_override) of
        undefined -> {error, nil};
        Val -> {ok, Val}
    end.

set_home_override(Val) ->
    erlang:put(hermes_home_override, Val),
    ok.

erase_home_override() ->
    erlang:erase(hermes_home_override),
    ok.

get_fallback_warned() ->
    case erlang:get(hermes_profile_fallback_warned) of
        true -> true;
        _ -> false
    end.

set_fallback_warned() ->
    erlang:put(hermes_profile_fallback_warned, true),
    ok.

get_packaged_data_dir(Name) ->
    NameStr = binary_to_list(Name),
    PrivDir = case code:priv_dir(hermes_beam) of
        {error, _} -> "";
        D1 -> D1
    end,
    LibDir = case code:lib_dir(hermes_beam) of
        {error, _} -> "";
        D2 -> D2
    end,
    Candidates = [
        filename:join([PrivDir, NameStr]),
        filename:join([LibDir, NameStr])
    ],
    ValidCandidates = [C || C <- Candidates, C /= "", filelib:is_dir(C)],
    case ValidCandidates of
        [First | _] -> {ok, list_to_binary(First)};
        [] -> {error, nil}
    end.

write_stderr(Msg) ->
    io:put_chars(standard_error, binary_to_list(Msg)),
    ok.

apply_ipv4_preference(true) ->
    application:set_env(kernel, inet_default_connect_options, [inet]),
    application:set_env(kernel, inet_default_listen_options, [inet]),
    ok;
apply_ipv4_preference(false) ->
    ok.

resolve_path(Path) ->
    list_to_binary(filename:absname(binary_to_list(Path))).

is_wsl() ->
    case erlang:get(hermes_wsl_detected) of
        undefined ->
            Detected = detect_wsl(),
            erlang:put(hermes_wsl_detected, Detected),
            Detected;
        Val -> Val
    end.

detect_wsl() ->
    case file:read_file("/proc/version") of
        {ok, Binary} ->
            Lower = string:casefold(Binary),
            case binary:match(Lower, <<"microsoft">>) of
                nomatch -> false;
                _ -> true
            end;
        _ ->
            false
    end.

is_container() ->
    case erlang:get(hermes_container_detected) of
        undefined ->
            Detected = detect_container(),
            erlang:put(hermes_container_detected, Detected),
            Detected;
        Val -> Val
    end.

detect_container() ->
    case filelib:is_regular("/.dockerenv") of
        true -> true;
        false ->
            case filelib:is_regular("/run/.containerenv") of
                true -> true;
                false ->
                    case file:read_file("/proc/1/cgroup") of
                        {ok, Binary} ->
                            Lower = string:casefold(Binary),
                            HasDocker = binary:match(Lower, <<"docker">>) /= nomatch,
                            HasPodman = binary:match(Lower, <<"podman">>) /= nomatch,
                            HasLxc = binary:match(Lower, <<"/lxc/">>) /= nomatch,
                            HasDocker orelse HasPodman orelse HasLxc;
                        _ ->
                            false
                    end
            end
    end.
