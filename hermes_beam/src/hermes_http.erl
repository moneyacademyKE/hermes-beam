-module(hermes_http).
-export([fetch/1, fetch_with_headers/2, post/4, post_with_retry/4, stream_post/4, decode_http_message/2, acquire_port_lock/1, release_port_lock/1, identity/1]).

%% ─── Retry helper ────────────────────────────────────────────────────────────
%% Retries the given fun up to MaxRetries times with exponential backoff
%% starting at InitDelayMs. Only retries on transient errors (429, 503, 502, connection errors).

retry(_, 0, _InitDelayMs, LastResult) ->
    LastResult;
retry(Fun, RetriesLeft, DelayMs, _) ->
    Result = Fun(),
    case Result of
        {error, Bin} when is_binary(Bin) ->
            %% Check if this is a retryable status code
            IsRetryable = is_retryable_error(Bin),
            if
                IsRetryable andalso RetriesLeft > 0 ->
                    timer:sleep(DelayMs),
                    retry(Fun, RetriesLeft - 1, DelayMs * 2, Result);
                true ->
                    Result
            end;
        {error, _} ->
            %% Connection error — always retry
            timer:sleep(DelayMs),
            retry(Fun, RetriesLeft - 1, DelayMs * 2, Result);
        _ ->
            Result
    end.

is_retryable_error(Bin) ->
    B = binary_to_list(Bin),
    lists:prefix("HTTP 429", B) orelse
    lists:prefix("HTTP 502", B) orelse
    lists:prefix("HTTP 503", B) orelse
    lists:prefix("Connection Error", B).

%% ─── Fetch (GET, no retry) ───────────────────────────────────────────────────

fetch(UrlBin) ->
    Url = binary_to_list(UrlBin),
    _ = ssl:start(),
    _ = inets:start(),
    case httpc:request(get, {Url, []}, [{timeout, 10000}], []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            {ok, list_to_binary(Body)};
        {ok, {{_, Status, _}, _, _}} ->
            {error, list_to_binary(io_lib:format("HTTP ~p", [Status]))};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("Connection Error: ~p", [Reason]))}
    end.

fetch_with_headers(UrlBin, HeadersList) ->
    Url = binary_to_list(UrlBin),
    Headers = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- HeadersList],
    _ = ssl:start(),
    _ = inets:start(),
    case httpc:request(get, {Url, Headers}, [{timeout, 10000}], []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            {ok, list_to_binary(Body)};
        {ok, {{_, Status, _}, _, _}} ->
            {error, list_to_binary(io_lib:format("HTTP ~p", [Status]))};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("Connection Error: ~p", [Reason]))}
    end.

%% ─── POST (sync, no retry) ───────────────────────────────────────────────────

post(UrlBin, HeadersList, ContentTypeBin, BodyBin) ->
    Url = binary_to_list(UrlBin),
    Headers = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- HeadersList],
    ContentType = binary_to_list(ContentTypeBin),
    Body = binary_to_list(BodyBin),
    _ = ssl:start(),
    _ = inets:start(),
    case httpc:request(post, {Url, Headers, ContentType, Body}, [{timeout, 120000}], []) of
        {ok, {{_, 200, _}, _Headers, RespBody}} ->
            {ok, list_to_binary(RespBody)};
        {ok, {{_, Status, _}, _, _}} ->
            {error, list_to_binary(io_lib:format("HTTP ~p", [Status]))};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("Connection Error: ~p", [Reason]))}
    end.

%% ─── POST with exponential backoff retry (sync) ──────────────────────────────
%% Used for non-streaming fallback calls. Retries up to 3 times on 429/502/503.

post_with_retry(UrlBin, HeadersList, ContentTypeBin, BodyBin) ->
    _ = ssl:start(),
    _ = inets:start(),
    Fun = fun() -> post(UrlBin, HeadersList, ContentTypeBin, BodyBin) end,
    retry(Fun, 3, 1000, {error, <<"Not started">>}).

%% ─── Stream POST (async) ─────────────────────────────────────────────────────

stream_post(UrlBin, HeadersList, ContentTypeBin, BodyBin) ->
    Url = binary_to_list(UrlBin),
    Headers = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- HeadersList],
    ContentType = binary_to_list(ContentTypeBin),
    Body = binary_to_list(BodyBin),
    _ = ssl:start(),
    _ = inets:start(),
    case httpc:request(post, {Url, Headers, ContentType, Body}, [], [{sync, false}, {stream, self}]) of
        {ok, RequestId} -> {ok, RequestId};
        {error, Reason} -> {error, list_to_binary(io_lib:format("Connection Error: ~p", [Reason]))}
    end.

%% ─── Stream message decoder ───────────────────────────────────────────────────

decode_http_message(Payload, TargetReqId) ->
    case Payload of
        {ReqId, stream_start, Headers} when ReqId =:= TargetReqId ->
            {decoded_start, [{list_to_binary(K), list_to_binary(V)} || {K, V} <- Headers]};
        {ReqId, stream, BodyPart} when ReqId =:= TargetReqId ->
            {decoded_stream, list_to_binary(BodyPart)};
        {ReqId, stream_end, _Headers} when ReqId =:= TargetReqId ->
            decoded_end;
        {ReqId, {error, Reason}} when ReqId =:= TargetReqId ->
            {decoded_error, list_to_binary(io_lib:format("~p", [Reason]))};
        {ReqId, {{_Version, Status, _ReasonPhrase}, _Headers, Body}} when ReqId =:= TargetReqId ->
            {decoded_error, list_to_binary(io_lib:format("HTTP ~p: ~s", [Status, Body]))};
        _ ->
            decoded_ignored
    end.

acquire_port_lock(Port) ->
    case gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, false}]) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

release_port_lock(Socket) ->
    gen_tcp:close(Socket).

identity(X) ->
    X.
