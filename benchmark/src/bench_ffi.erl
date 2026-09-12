-module(bench_ffi).
-export([split_requests/1, response/1, head/0, body/0,
         mode/0, port/0, pool/0, buffer/0]).

-define(HEAD, <<"HTTP/1.1 200 OK\r\ncontent-length: 5\r\ncontent-type: text/plain\r\n\r\n">>).
-define(CLOSE_HEAD, <<"HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 5\r\ncontent-type: text/plain\r\n\r\n">>).
-define(BODY, <<"hello">>).

split_requests(Buffer) ->
  case binary:matches(Buffer, <<"\r\n\r\n">>) of
    [] -> {0, Buffer};
    Matches ->
      {Position, Length} = lists:last(Matches),
      End = Position + Length,
      {length(Matches), binary:part(Buffer, End, byte_size(Buffer) - End)}
  end.

response(Count) ->
  case mode() of
    <<"close">> -> <<?CLOSE_HEAD/binary, ?BODY/binary>>;
    _Other -> binary:copy(<<?HEAD/binary, ?BODY/binary>>, Count)
  end.

head() -> ?HEAD.
body() -> ?BODY.

mode() -> list_to_binary(os:getenv("BENCH_MODE", "keepalive")).
port() -> list_to_integer(os:getenv("BENCH_PORT", "4000")).
pool() -> list_to_integer(os:getenv("BENCH_POOL", "10")).
buffer() -> list_to_integer(os:getenv("BENCH_BUFFER", "0")).
