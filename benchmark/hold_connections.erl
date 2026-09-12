#!/usr/bin/env escript
%% Usage: escript hold_connections.erl <port> <count>
%%
%% Opens <count> idle connections to 127.0.0.1:<port>, prints "held" once all
%% of them are open and keeps them open until its stdin closes.

main([Port, Count]) ->
    Connect = fun(_Index) ->
        case gen_tcp:connect({127, 0, 0, 1}, list_to_integer(Port), [{active, false}]) of
            {ok, Socket} ->
                Socket;
            {error, Reason} ->
                io:format(standard_error, "connect: ~p~n", [Reason]),
                halt(1)
        end
    end,
    _Sockets = lists:map(Connect, lists:seq(1, list_to_integer(Count))),
    io:format("held~n"),
    io:get_line("").
