// import gleam/bytes_tree
// import gleam/dynamic/decode
// import gleam/erlang/process
// import gleam/list
// import gleam/option
// import pooler/socket

// pub type ClientSocket

// @external(erlang, "pooler_socket_ffi_test_helper", "client_connect")
// fn connect(port: Int) -> Result(ClientSocket, a)

// @external(erlang, "gen_tcp", "send")
// fn client_send(socket: ClientSocket, data: BitArray) -> a

// @external(erlang, "gen_tcp", "recv")
// fn client_receive(socket: ClientSocket, bytes: Int) -> Result(BitArray, a)

// fn options() -> List(socket.TcpOption) {
//   [
//     socket.Active(socket.Passive),
//     socket.ReuseAddress(True),
//     socket.NoDelay(True),
//     socket.DelaySend(False),
//     socket.KeepAlive(True),
//     socket.Linger(enabled: True, seconds: 5),
//     socket.SendTimeout(socket.Milliseconds(30_000)),
//     socket.SendTimeoutClose(True),
//     socket.ExitOnClose(True),
//     socket.ShowConnectionReset(True),
//     socket.Buffer(4096),
//     socket.ReceiveBuffer(8192),
//     socket.SendBuffer(8192),
//     socket.HighWatermark(16_384),
//     socket.LowWatermark(4096),
//     socket.HighMessageQueueWatermark(16_384),
//     socket.LowMessageQueueWatermark(4096),
//     socket.Backlog(512),
//     socket.BindAddress(socket.Loopback),
//     socket.Family(socket.Inet),
//   ]
// }

// pub fn tcp_round_trip_test() {
//   let assert Ok(#(transport, listener)) = socket.listen(0, options())
//   assert transport == socket.Tcp

//   let assert Ok(#(socket.Ipv4(127, 0, 0, 1), port)) =
//     socket.sockname_listener(transport, listener)

//   let assert Ok(client) = connect(port)

//   let assert Ok(server) =
//     socket.accept(transport, listener, socket.Milliseconds(1000))
//   let assert Ok(#(socket.Ipv4(127, 0, 0, 1), _client_port)) =
//     socket.peername(transport, server)

//   let assert Ok(#(socket.Ipv4(127, 0, 0, 1), local_port)) =
//     socket.sockname(transport, server)
//   assert local_port == port

//   let assert Error(socket.Unsupported) =
//     socket.negotiated_protocol(transport, server)
//   let assert Error(socket.Unsupported) =
//     socket.peer_certificate(transport, server)

//   let _sent = client_send(client, <<"ping">>)
//   let assert Ok(<<"ping">>) =
//     socket.receive(transport, server, 0, socket.Milliseconds(1000))

//   let assert Ok(Nil) =
//     socket.send(transport, server, bytes_tree.from_string("pong"))
//   let assert Ok(<<"pong">>) = client_receive(client, 0)

//   let assert Ok(Nil) =
//     socket.controlling_process(transport, server, process.self())
//   let assert Ok(Nil) =
//     socket.set_options(transport, server, [socket.Active(socket.Packets(1))])

//   let _sent = client_send(client, <<"again">>)
//   let selector = socket.selector(transport)
//   let assert Ok(socket.Incoming(<<"again">>)) =
//     process.selector_receive(selector, 1000)
//   let assert Ok(socket.Exhausted) = process.selector_receive(selector, 1000)

//   let assert Ok(Nil) = socket.shutdown(transport, server, socket.ReadWrite)
//   let assert Ok(Nil) = socket.close(transport, server)
//   let assert Ok(Nil) = socket.close_listener(transport, listener)
// }

// pub fn listen_error_test() {
//   let assert Ok(#(transport, listener)) = socket.listen(0, options())
//   let assert Ok(#(_address, port)) =
//     socket.sockname_listener(transport, listener)
//   let assert Error(socket.Eaddrinuse) =
//     socket.listen(port, [
//       socket.ReuseAddress(False),
//       socket.BindAddress(socket.Loopback),
//     ])
//   let assert Ok(Nil) = socket.close_listener(transport, listener)
// }

// pub fn tls_options_test() {
//   let tls_options = [
//     socket.CertificateKeys([
//       socket.CertificateFiles("missing.pem", "missing.key", option.None),
//     ]),
//     socket.Verify(socket.VerifyNone),
//     socket.FailWithoutPeerCertificate(False),
//     socket.Depth(3),
//     socket.Versions([socket.Tls13, socket.Tls12]),
//     socket.AlpnPreferredProtocols([<<"h2">>, <<"http/1.1">>]),
//     socket.HonorCipherOrder(True),
//     socket.ReuseSessions(True),
//     socket.SessionTickets(socket.Stateless),
//     socket.HibernateAfter(30_000),
//     socket.MaximumHandshakeSize(16_384),
//     socket.Logging(socket.LogNothing),
//   ]
//   let assert Error(socket.Failure(reason)) =
//     socket.listen_tls(0, options(), tls_options)

//   let assert Error(_not_a_string) = decode.run(reason, decode.string)
// }

// pub fn certificate_chain_test() {
//   let der = <<1, 2, 3>>
//   let keys = [
//     socket.RsaPrivateKey(der),
//     socket.DsaPrivateKey(der),
//     socket.EcPrivateKey(der),
//     socket.PrivateKeyInfo(der),
//   ]

//   use key <- list.each(keys)
//   let assert Ok(#(transport, listener)) =
//     socket.listen_tls(0, options(), [
//       socket.CertificateKeys([socket.CertificateChain([der], key)]),
//       socket.Logging(socket.LogNothing),
//     ])
//   let assert Ok(Nil) = socket.close_listener(transport, listener)
// }

// const certificate_pem = "-----BEGIN CERTIFICATE-----
// MIIBfzCCASWgAwIBAgIUOOx9q1SYa40OImMDrrJPnmY+oTIwCgYIKoZIzj0EAwIw
// FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDkwNTEyMzMyMVoYDzIxMjYwODEy
// MTIzMzIxWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
// PQMBBwNCAAQ8Mq5m66wlxFx2grkYImfIoJKgvcxd2PSKB2DuuKeE1iV9ylAXpFO/
// 3WEZzHhelMi4P277ZBabIfVSLVxtYraNo1MwUTAdBgNVHQ4EFgQUCbix3Eom89dc
// SJWq2UdU1HM6ZF0wHwYDVR0jBBgwFoAUCbix3Eom89dcSJWq2UdU1HM6ZF0wDwYD
// VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAwfRyae1mF7uJt25MLVrd
// TvsXCps891zKCdZXcp/zqZ0CIETMxagcd3Nu8La4oQP8eE+/TERnpjyuG96/YjIe
// 5e1Z
// -----END CERTIFICATE-----
// "

// const key_pem = "-----BEGIN PRIVATE KEY-----
// MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg6W5uFWd0RIQD856+
// CO182Vb1HlEu4+cmnWYYS+OVsjmhRANCAAQ8Mq5m66wlxFx2grkYImfIoJKgvcxd
// 2PSKB2DuuKeE1iV9ylAXpFO/3WEZzHhelMi4P277ZBabIfVSLVxtYraN
// -----END PRIVATE KEY-----
// "

// const encrypted_key_pem = "-----BEGIN ENCRYPTED PRIVATE KEY-----
// MIH0MF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBADIQjVC+3rreKYKuDz
// HIttAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQE3869h0//MmyztFF
// jh9NzASBkGC1IxgsCoJAZLd0oB0daKEPC1RjC4EnV7PlrEIn0hBWAyE8MAwNaDr2
// QhSKEmSgTEFFty41ssidgsV59aIyDj/TG6Qall9cfSHOgXm4joeBvrVUnnzKAq06
// +t8XRWyDePgyMNzXQzoGHskNHsvhQ/382vZC5g84js3EyL//c+nOJ7HM7GnOdzeu
// 77K6Oj8V8A==
// -----END ENCRYPTED PRIVATE KEY-----
// "

// pub fn pem_certificate_chain_test() {
//   let chain = socket.certificates_from_pem(<<certificate_pem:utf8>>)
//   let assert [_certificate] = chain
//   let assert Ok(key) = socket.private_key_from_pem(<<key_pem:utf8>>)
//   let assert socket.PrivateKeyInfo(_der) = key

//   let assert Ok(#(transport, listener)) =
//     socket.listen_tls(0, options(), [
//       socket.CertificateKeys([socket.CertificateChain(chain, key)]),
//       socket.Logging(socket.LogNothing),
//     ])
//   let assert Ok(Nil) = socket.close_listener(transport, listener)
// }

// pub fn pem_without_usable_key_test() {
//   assert socket.certificates_from_pem(<<"not pem at all":utf8>>) == []
//   assert socket.private_key_from_pem(<<certificate_pem:utf8>>)
//     == Error(socket.NoPrivateKey)
//   assert socket.private_key_from_pem(<<encrypted_key_pem:utf8>>)
//     == Error(socket.EncryptedPrivateKey)
// }

// pub fn tls_alert_test() {
//   let assert Ok(#(transport, listener)) =
//     socket.listen_tls(0, options(), [socket.Logging(socket.LogNothing)])
//   let assert Ok(#(_address, port)) =
//     socket.sockname_listener(transport, listener)
//   let assert Ok(client) = connect(port)

//   let _sent = client_send(client, <<22, 3, 1, 0, 9, 1, 0, 0, 5, 3, 3, 0, 0, 0>>)

//   let assert Ok(server) =
//     socket.accept(transport, listener, socket.Milliseconds(5000))
//   let assert Error(socket.TlsAlert(socket.DecodeError, detail)) =
//     socket.handshake(transport, server, socket.Milliseconds(5000))
//   assert detail != ""

//   let assert Ok(Nil) = socket.close_listener(transport, listener)
// }
