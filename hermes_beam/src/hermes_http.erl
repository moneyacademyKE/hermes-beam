-module(hermes_http).
-export([fetch/1, fetch_with_headers/2, post/4, stream_post/4, decode_http_message/2]).

fetch(UrlBin) ->
    Url = binary_to_list(UrlBin),
    _ = ssl:start(),
    _ = inets:start(),
    case httpc:request(get, {Url, []}, [{timeout, 10000}], []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            {ok, list_to_binary(Body)};
        {ok, {{_, Status, _}, _, _}} ->
            {error, Status};
        {error, Reason} ->
            {error, {conn_error, Reason}}
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
            {error, Status};
        {error, Reason} ->
            {error, {conn_error, Reason}}
    end.

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
            {error, Status};
        {error, Reason} ->
            {error, {conn_error, Reason}}
    end.

stream_post(UrlBin, HeadersList, ContentTypeBin, BodyBin) ->
    Url = binary_to_list(UrlBin),
    Headers = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- HeadersList],
    ContentType = binary_to_list(ContentTypeBin),
    Body = binary_to_list(BodyBin),
    _ = ssl:start(),
    _ = inets:start(),
    case httpc:request(post, {Url, Headers, ContentType, Body}, [], [{sync, false}, {stream, self}]) of
        {ok, RequestId} -> {ok, RequestId};
        {error, Reason} -> {error, {conn_error, Reason}}
    end.

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
        _ ->
            decoded_ignored
    end.


