-module(tup_ffi).

-include_lib("kernel/include/file.hrl").

-export([parse_address/1, unlink_stale_socket/1, read_file/1]).

parse_address(Address) ->
  case inet:parse_address(binary_to_list(Address)) of
    {ok, {A, B, C, D}} ->
      {ok, {ipv4, A, B, C, D}};
    {ok, {A, B, C, D, E, F, G, H}} ->
      {ok, {ipv6, A, B, C, D, E, F, G, H}};
    {error, einval} ->
      {error, nil}
  end.

read_file(Path) ->
  case file:read_file(Path) of
    {ok, Bytes} -> {ok, Bytes};
    {error, Reason} -> {error, reason(Reason)}
  end.

unlink_stale_socket(Path) ->
  case file:read_link_info(Path) of
    {error, enoent} ->
      {ok, nil};
    {ok, #file_info{type = other}} ->
      case file:delete(Path) of
        ok ->
          {ok, nil};
        {error, enoent} ->
          {ok, nil};
        {error, Reason} ->
          {error, {path_not_removed, reason(Reason)}}
      end;
    {ok, #file_info{type = Kind}} ->
      {error, {path_not_socket, path_kind(Kind)}};
    {error, Reason} ->
      {error, {path_not_inspected, reason(Reason)}}
  end.

path_kind(device) -> device;
path_kind(directory) -> directory;
path_kind(regular) -> regular;
path_kind(symlink) -> symlink;
path_kind(_Kind) -> unknown_kind.

reason(Reason) when is_atom(Reason) ->
  atom_to_binary(Reason, utf8);
reason(Reason) ->
  unicode:characters_to_binary(io_lib:format("~p", [Reason])).