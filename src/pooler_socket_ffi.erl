-module(pooler_socket_ffi).

-include_lib("public_key/include/public_key.hrl").

-export([tcp_listen/2, tcp_accept/2, tcp_controlling_process/2, tcp_close/1,
         tcp_shutdown/2, tcp_send/2, tcp_receive/3, tcp_set_options/2,
         tcp_sockname/1, tcp_peername/1,
         ssl_listen/3, ssl_accept/2, ssl_handshake/2,
         ssl_controlling_process/2, ssl_close/1, ssl_shutdown/2, ssl_send/2,
         ssl_receive/3, ssl_set_options/2, ssl_sockname/1, ssl_peername/1,
         ssl_negotiated_protocol/1, ssl_peer_certificate/1,
         certificates_from_pem/1, private_key_from_pem/2,
         system_certificate_authorities/0,
         message/1, reason/1]).

-define(FIXED_OPTIONS, [binary, {packet, raw}]).

tcp_listen(Port, Options) ->
    outcome(gen_tcp:listen(Port, ?FIXED_OPTIONS ++ options(Options))).

tcp_accept(Socket, Timeout) ->
    outcome(gen_tcp:accept(Socket, timeout(Timeout))).

tcp_controlling_process(Socket, Pid) ->
    acknowledgement(gen_tcp:controlling_process(Socket, Pid)).

tcp_close(Socket) ->
    acknowledgement(gen_tcp:close(Socket)).

tcp_shutdown(Socket, Mode) ->
    acknowledgement(gen_tcp:shutdown(Socket, Mode)).

tcp_send(Socket, Data) ->
    acknowledgement(gen_tcp:send(Socket, Data)).

tcp_receive(Socket, Bytes, Timeout) ->
    outcome(gen_tcp:recv(Socket, Bytes, timeout(Timeout))).

tcp_set_options(Socket, Options) ->
    acknowledgement(inet:setopts(Socket, options(Options))).

tcp_sockname(Socket) ->
    endpoint(inet:sockname(Socket)).

tcp_peername(Socket) ->
    endpoint(inet:peername(Socket)).

ssl_listen(Port, Options, TlsOptions) ->
    outcome(ssl:listen(Port,
                       ?FIXED_OPTIONS ++ options(Options)
                       ++ tls_options(TlsOptions))).

ssl_accept(Socket, Timeout) ->
    outcome(ssl:transport_accept(Socket, timeout(Timeout))).

ssl_handshake(Socket, Timeout) ->
    outcome(ssl:handshake(Socket, timeout(Timeout))).

ssl_controlling_process(Socket, Pid) ->
    acknowledgement(ssl:controlling_process(Socket, Pid)).

ssl_close(Socket) ->
    acknowledgement(ssl:close(Socket)).

ssl_shutdown(Socket, Mode) ->
    acknowledgement(ssl:shutdown(Socket, Mode)).

ssl_send(Socket, Data) ->
    acknowledgement(ssl:send(Socket, Data)).

ssl_receive(Socket, Bytes, Timeout) ->
    outcome(ssl:recv(Socket, Bytes, timeout(Timeout))).

ssl_set_options(Socket, Options) ->
    acknowledgement(ssl:setopts(Socket, options(Options))).

ssl_sockname(Socket) ->
    endpoint(ssl:sockname(Socket)).

ssl_peername(Socket) ->
    endpoint(ssl:peername(Socket)).

ssl_negotiated_protocol(Socket) ->
    outcome(ssl:negotiated_protocol(Socket)).

ssl_peer_certificate(Socket) ->
    outcome(ssl:peercert(Socket)).

system_certificate_authorities() ->
    [Der || #cert{der = Der} <- public_key:cacerts_get()].

certificates_from_pem(Pem) ->
    [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)].

private_key_from_pem(Pem, Password) ->
    private_key_entry([Entry
                       || Entry <- public_key:pem_decode(Pem),
                          is_private_key(Entry)],
                      Password).

is_private_key({Type, _Der, _Cipher}) ->
    lists:member(Type,
                 ['RSAPrivateKey', 'DSAPrivateKey', 'ECPrivateKey',
                  'PrivateKeyInfo']).

private_key_entry([], _Password) ->
    {error, no_private_key};
private_key_entry([{Type, Der, not_encrypted} | _Rest], _Password) ->
    {ok, private_key(Type, Der)};
private_key_entry([_Entry | _Rest], none) ->
    {error, encrypted_private_key};
private_key_entry([Entry | _Rest], {some, Password}) ->
    try public_key:pem_entry_decode(Entry, binary_to_list(Password)) of
        Decoded ->
            Type = element(1, Decoded),
            {ok, private_key(Type, public_key:der_encode(Type, Decoded))}
    catch
        _Class:_Reason -> {error, wrong_password}
    end.

private_key('RSAPrivateKey', Der) -> {rsa_private_key, Der};
private_key('DSAPrivateKey', Der) -> {dsa_private_key, Der};
private_key('ECPrivateKey', Der) -> {ec_private_key, Der};
private_key('PrivateKeyInfo', Der) -> {private_key_info, Der}.

acknowledgement(ok) -> {ok, nil};
acknowledgement({error, Reason}) -> {error, reason(Reason)}.

outcome({ok, Value}) -> {ok, Value};
outcome({error, Reason}) -> {error, reason(Reason)}.

endpoint({ok, {local, Path}}) -> {ok, {unix_endpoint, Path}};
endpoint({ok, {Address, Port}}) -> {ok, {tcp_endpoint, ip_address(Address), Port}};
endpoint({error, Reason}) -> {error, reason(Reason)}.

reason({tls_alert, {Description, Detail}}) ->
    {tls_alert, alert(Description), unicode:characters_to_binary(Detail)};
reason(protocol_not_negotiated) -> not_negotiated;
reason(no_peercert) -> no_peer_certificate;
reason(closed) -> closed;
reason(timeout) -> timeout;
reason(not_owner) -> not_owner;
reason(system_limit) -> system_limit;
reason(eacces) -> eacces;
reason(eaddrinuse) -> eaddrinuse;
reason(eaddrnotavail) -> eaddrnotavail;
reason(eafnosupport) -> eafnosupport;
reason(eagain) -> eagain;
reason(ealready) -> ealready;
reason(ebadf) -> ebadf;
reason(econnaborted) -> econnaborted;
reason(econnrefused) -> econnrefused;
reason(econnreset) -> econnreset;
reason(ehostdown) -> ehostdown;
reason(ehostunreach) -> ehostunreach;
reason(einprogress) -> einprogress;
reason(eintr) -> eintr;
reason(einval) -> einval;
reason(eio) -> eio;
reason(eisconn) -> eisconn;
reason(emfile) -> emfile;
reason(emsgsize) -> emsgsize;
reason(enetdown) -> enetdown;
reason(enetreset) -> enetreset;
reason(enetunreach) -> enetunreach;
reason(enfile) -> enfile;
reason(enobufs) -> enobufs;
reason(enomem) -> enomem;
reason(enoprotoopt) -> enoprotoopt;
reason(enotconn) -> enotconn;
reason(enotsock) -> enotsock;
reason(enotsup) -> enotsup;
reason(eperm) -> eperm;
reason(epipe) -> epipe;
reason(eproto) -> eproto;
reason(eprotonosupport) -> eprotonosupport;
reason(eprototype) -> eprototype;
reason(etimedout) -> etimedout;
reason(ewouldblock) -> ewouldblock;
reason(exbadport) -> exbadport;
reason(exbadseq) -> exbadseq;
reason(nooptions) ->
    {bad_tls_option, <<"certs_keys">>, <<"no certificate was given">>};
reason({option, client_only, Option}) ->
    {bad_tls_option,
     atom_to_binary(Option, utf8),
     <<"it is a client option and does nothing on a listen socket">>};
reason({options, incompatible, Options}) ->
    {bad_tls_option, <<"verify">>, text("~p cannot be combined", [Options])};
reason({options, {Option, {Path, Problem}}})
  when is_list(Path); is_binary(Path) ->
    {bad_tls_option, atom_to_binary(Option, utf8), file_problem(Path, Problem)};
reason({options, {Option, Value}}) when is_atom(Option) ->
    {bad_tls_option, atom_to_binary(Option, utf8), text("~p was refused", [Value])};
reason({options, Value}) ->
    {bad_tls_option, <<"options">>, text("~p was refused", [Value])};
reason(Reason) -> failure(Reason).

file_problem(Path, enoent) ->
    text("~ts does not exist", [Path]);
file_problem(Path, eacces) ->
    text("~ts could not be read, permission was denied", [Path]);
file_problem(Path, no_certs) ->
    text("~ts holds no certificate", [Path]);
file_problem(Path, wrong_password) ->
    text("~ts is encrypted and the password given does not decrypt it",
         [Path]);
file_problem(Path, Problem) ->
    text("~ts was refused, ~p", [Path, Problem]).

text(Format, Arguments) ->
    unicode:characters_to_binary(io_lib:format(Format, Arguments)).

alert(close_notify) -> close_notify;
alert(unexpected_message) -> unexpected_message;
alert(bad_record_mac) -> bad_record_mac;
alert(record_overflow) -> record_overflow;
alert(handshake_failure) -> handshake_failure;
alert(bad_certificate) -> bad_certificate;
alert(unsupported_certificate) -> unsupported_certificate;
alert(certificate_revoked) -> certificate_revoked;
alert(certificate_expired) -> certificate_expired;
alert(certificate_unknown) -> certificate_unknown;
alert(illegal_parameter) -> illegal_parameter;
alert(unknown_ca) -> unknown_ca;
alert(access_denied) -> access_denied;
alert(decode_error) -> decode_error;
alert(decrypt_error) -> decrypt_error;
alert(protocol_version) -> protocol_version;
alert(insufficient_security) -> insufficient_security;
alert(internal_error) -> internal_error;
alert(inappropriate_fallback) -> inappropriate_fallback;
alert(user_canceled) -> user_canceled;
alert(no_renegotiation) -> no_renegotiation;
alert(missing_extension) -> missing_extension;
alert(unsupported_extension) -> unsupported_extension;
alert(certificate_unobtainable) -> certificate_unobtainable;
alert(unrecognized_name) -> unrecognized_name;
alert(bad_certificate_status_response) -> bad_certificate_status_response;
alert(unknown_psk_identity) -> unknown_psk_identity;
alert(certificate_required) -> certificate_required;
alert(no_application_protocol) -> no_application_protocol;
alert(_Description) -> unknown_alert.

failure(Reason) ->
    {failure, Reason}.

message({Tag, _Socket, Data}) when Tag =:= tcp; Tag =:= ssl ->
    {incoming, Data};
message({Tag, _Socket, Reason}) when Tag =:= tcp_error; Tag =:= ssl_error ->
    {failed, reason(Reason)};
message({Tag, _Socket}) when Tag =:= tcp_closed; Tag =:= ssl_closed ->
    disconnected;
message({Tag, _Socket}) when Tag =:= tcp_passive; Tag =:= ssl_passive ->
    exhausted.

ip_address({A, B, C, D}) ->
    {ipv4, A, B, C, D};
ip_address({A, B, C, D, E, F, G, H}) ->
    {ipv6, A, B, C, D, E, F, G, H}.

from_ip_address({ipv4, A, B, C, D}) ->
    {A, B, C, D};
from_ip_address({ipv6, A, B, C, D, E, F, G, H}) ->
    {A, B, C, D, E, F, G, H}.

timeout({milliseconds, Milliseconds}) -> Milliseconds;
timeout(never) -> infinity.

options(Options) ->
    [option(Option) || Option <- Options].

option({active, State}) -> {active, active_state(State)};
option({reuse_address, Enabled}) -> {reuseaddr, Enabled};
option({reuse_port, Enabled}) -> {reuseport, Enabled};
option({no_delay, Enabled}) -> {nodelay, Enabled};
option({delay_send, Enabled}) -> {delay_send, Enabled};
option({keep_alive, Enabled}) -> {keepalive, Enabled};
option({linger, Enabled, Seconds}) -> {linger, {Enabled, Seconds}};
option({send_timeout, Timeout}) -> {send_timeout, timeout(Timeout)};
option({send_timeout_close, Enabled}) -> {send_timeout_close, Enabled};
option({exit_on_close, Enabled}) -> {exit_on_close, Enabled};
option({show_connection_reset, Enabled}) -> {show_econnreset, Enabled};
option({buffer, Size}) -> {buffer, Size};
option({receive_buffer, Size}) -> {recbuf, Size};
option({send_buffer, Size}) -> {sndbuf, Size};
option({high_watermark, Size}) -> {high_watermark, Size};
option({low_watermark, Size}) -> {low_watermark, Size};
option({high_message_queue_watermark, Size}) -> {high_msgq_watermark, Size};
option({low_message_queue_watermark, Size}) -> {low_msgq_watermark, Size};
option({backlog, Size}) -> {backlog, Size};
option({bind_address, Interface}) -> {ip, interface(Interface)};
option({family, inet}) -> inet;
option({family, inet6}) -> inet6;
option({ipv6_only, Enabled}) -> {ipv6_v6only, Enabled};
option({file_descriptor, Descriptor}) -> {fd, Descriptor}.

active_state(passive) -> false;
active_state(always) -> true;
active_state(once) -> once;
active_state({packets, Count}) -> Count.

interface({address, Address}) -> from_ip_address(Address);
interface(any) -> any;
interface(loopback) -> loopback;
interface({local, Path}) -> {local, Path}.

tls_options(Options) ->
    [tls_option(Option) || Option <- Options].

tls_option({certificate_keys, Entries}) ->
    {certs_keys, [certificate_key(Entry) || Entry <- Entries]};
tls_option({server_name_certificates, Hosts}) ->
    {sni_hosts,
     [{binary_to_list(Host), [{certs_keys, [certificate_key(Entry)]}]}
      || {Host, Entry} <- Hosts]};
tls_option({certificate_authority_file, Path}) -> {cacertfile, Path};
tls_option({certificate_authorities, Certificates}) -> {cacerts, Certificates};
tls_option({send_certificate_authorities, Enabled}) ->
    {certificate_authorities, Enabled};
tls_option({verify, Mode}) -> {verify, Mode};
tls_option({fail_without_peer_certificate, Enabled}) ->
    {fail_if_no_peer_cert, Enabled};
tls_option({depth, Depth}) -> {depth, Depth};
tls_option({crl_check, Mode}) -> {crl_check, crl_mode(Mode)};
tls_option({versions, Versions}) ->
    {versions, [tls_version(Version) || Version <- Versions]};
tls_option({supported_groups, Groups}) ->
    {supported_groups, [key_exchange_group(Group) || Group <- Groups]};
tls_option({alpn_preferred_protocols, Protocols}) ->
    {alpn_preferred_protocols, Protocols};
tls_option({honor_cipher_order, Enabled}) -> {honor_cipher_order, Enabled};
tls_option({reuse_sessions, Enabled}) -> {reuse_sessions, Enabled};
tls_option({secure_renegotiate, Enabled}) -> {secure_renegotiate, Enabled};
tls_option({client_renegotiation, Enabled}) -> {client_renegotiation, Enabled};
tls_option({session_tickets, Mode}) -> {session_tickets, ticket_mode(Mode)};
tls_option({diffie_hellman_file, Path}) -> {dhfile, Path};
tls_option({hibernate_after, Milliseconds}) -> {hibernate_after, Milliseconds};
tls_option({maximum_handshake_size, Size}) -> {max_handshake_size, Size};
tls_option({logging, Level}) -> {log_level, log_level(Level)}.

certificate_key({certificate_files, CertificateFile, KeyFile, none}) ->
    #{certfile => CertificateFile, keyfile => KeyFile};
certificate_key({certificate_files, CertificateFile, KeyFile,
                 {some, Password}}) ->
    #{certfile => CertificateFile, keyfile => KeyFile, password => Password};
certificate_key({certificate_chain, Chain, Key}) ->
    #{cert => Chain, key => from_private_key(Key)}.

from_private_key({rsa_private_key, Der}) -> {'RSAPrivateKey', Der};
from_private_key({dsa_private_key, Der}) -> {'DSAPrivateKey', Der};
from_private_key({ec_private_key, Der}) -> {'ECPrivateKey', Der};
from_private_key({private_key_info, Der}) -> {'PrivateKeyInfo', Der}.

tls_version(tls13) -> 'tlsv1.3';
tls_version(tls12) -> 'tlsv1.2'.

crl_mode(crl_disabled) -> false;
crl_mode(crl_whole_chain) -> true;
crl_mode(crl_peer_only) -> peer;
crl_mode(crl_best_effort) -> best_effort.

key_exchange_group(x25519) -> x25519;
key_exchange_group(x448) -> x448;
key_exchange_group(secp256r1) -> secp256r1;
key_exchange_group(secp384r1) -> secp384r1;
key_exchange_group(secp521r1) -> secp521r1;
key_exchange_group(ffdhe2048) -> ffdhe2048;
key_exchange_group(ffdhe3072) -> ffdhe3072;
key_exchange_group(ffdhe4096) -> ffdhe4096;
key_exchange_group(ffdhe6144) -> ffdhe6144;
key_exchange_group(ffdhe8192) -> ffdhe8192.

ticket_mode(tickets_disabled) -> disabled;
ticket_mode(stateful) -> stateful;
ticket_mode(stateless) -> stateless.

log_level(log_nothing) -> none;
log_level(log_error) -> error;
log_level(log_warning) -> warning;
log_level(log_notice) -> notice;
log_level(log_information) -> info;
log_level(log_debug) -> debug;
log_level(log_everything) -> all.
