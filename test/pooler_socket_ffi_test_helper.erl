-module(pooler_socket_ffi_test_helper).

-export([client_connect/1]).

client_connect(Port) ->
    gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]).
