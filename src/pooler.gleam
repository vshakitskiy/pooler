// Root Supervisor, RestForOne relay_supervisor
// │
// ├─ Listener worker
// │  opens the TCP listen socket
// │  passes socket
// ├─ Connection Supervisor, OneForOne Transient factory_supervisor
// │  holds the template for handling one accepted connection
// │  passes socket and a reference to itself
// └─ Acceptor Pool, OneForOne static_supervisor
//    │
//    ├─ Acceptor worker 1 ┐
//    │                    │ N independent siblings, accepting on a socket
//    ├─ Acceptor worker 2 │ on accept, hand the connection to the connection
//    │                    │ supervisor then loop back to accept again
//    ┆                    │
//    ├─ Acceptor worker N ┘

import gleam/bit_array
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import pooler/internals/connection
import pooler/internals/file
import pooler/internals/listener
import pooler/internals/pool
import pooler/socket
import relay_supervisor as relay

pub opaque type Builder {
  Builder(
    address: Address,
    tls: option.Option(Tls),
    active_state: socket.ActiveState,
    pool_size: Int,
  )
}

pub fn new() -> Builder {
  Builder(
    address: Tcp(interface: "127.0.0.1", port: 3000),
    tls: option.None,
    active_state: socket.Once,
    pool_size: 20,
  )
}

pub type Address {
  Tcp(interface: String, port: Int)
  Unix(path: String)
}

pub fn listening(builder: Builder, on address: Address) {
  Builder(..builder, address:)
}

pub opaque type Tls {
  Tls(
    certificate: Certificate,
    client_certificates: option.Option(ClientCertificates),
    alpn: List(String),
    session_tickets: TicketMode,
  )
}

pub type Certificate {
  Disk(cert: String, key: String)
  EncryptedDisk(cert: String, key: String, password: String)
  Pem(cert: BitArray, key: BitArray)
  EncryptedPem(cert: BitArray, key: BitArray, password: String)
  Der(chain: List(BitArray), key: TlsPrivateKey)
}

pub type TlsPrivateKey {
  /// A PKCS #1 `RSAPrivateKey`.
  RsaPrivateKey(BitArray)
  /// A `DSAPrivateKey`.
  DsaPrivateKey(BitArray)
  /// A SEC 1 `ECPrivateKey`.
  EcPrivateKey(BitArray)
  /// A PKCS #8 `PrivateKeyInfo`.
  PrivateKeyInfo(BitArray)
}

fn to_internal_key(key: TlsPrivateKey) -> socket.PrivateKey {
  case key {
    RsaPrivateKey(key) -> socket.RsaPrivateKey(key)
    DsaPrivateKey(key) -> socket.DsaPrivateKey(key)
    EcPrivateKey(key) -> socket.EcPrivateKey(key)
    PrivateKeyInfo(key) -> socket.PrivateKeyInfo(key)
  }
}

pub fn tls(certificate: Certificate) {
  Tls(
    certificate:,
    client_certificates: option.None,
    alpn: [],
    session_tickets: Stateless,
  )
}

pub type ClientCertificates {
  Requested(trusting: TrustStore)
  Required(trusting: TrustStore)
}

pub type TrustStore {
  SystemTrustStore
  TrustDisk(path: String)
  TrustPem(bytes: BitArray)
  TrustDer(certificates: List(BitArray))
}

pub fn verifying_clients(tls: Tls, on: ClientCertificates) {
  Tls(..tls, client_certificates: option.Some(on))
}

pub fn with_alpn(tls: Tls, protocols: List(String)) {
  Tls(..tls, alpn: protocols)
}

pub type TicketMode {
  NoTickets
  Stateful
  Stateless
}

fn to_internal_ticket_mode(mode: TicketMode) -> socket.TicketMode {
  case mode {
    NoTickets -> socket.TicketsDisabled
    Stateful -> socket.Stateful
    Stateless -> socket.Stateless
  }
}

pub fn session_tickets(tls: Tls, mode: TicketMode) {
  Tls(..tls, session_tickets: mode)
}

pub fn with_tls(builder: Builder, tls: Tls) {
  Builder(..builder, tls: option.Some(tls))
}

pub fn supervised(builder: Builder) {
  use <- supervision.supervisor
  start(builder)
}

pub fn start(builder: Builder) {
  use address <- result.try(case builder.address {
    Tcp(interface:, port:) -> {
      use <- try_port(port)
      use interface <- try_interface(interface)
      Ok(listener.Tcp(interface:, port:))
    }
    Unix(path:) -> {
      use <- try_unix_path(path)
      Ok(listener.Unix(path:))
    }
  })
  use tls <- try_tls(builder.tls)

  let listener_argument =
    listener.Argument(address:, tls:, active_state: builder.active_state)

  relay.new(fn(children) {
    listener.add_child(children, listener_argument)
    |> connection.add_child
    |> pool.add_child(pool_size: builder.pool_size)
  })
  |> relay.start
}

fn try_port(
  port: Int,
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case port {
    port if port < 0 || port > 65_535 -> {
      logging.log(logging.Warning, "Invalid port provided!")
      Error(actor.InitFailed("Port provided outside of a 0..65535 window."))
    }
    _port -> callback()
  }
}

fn try_interface(
  interface: String,
  callback: fn(socket.Interface) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case interface, parse_address(interface) {
    "0.0.0.0", _ -> callback(socket.Any)
    "localhost", _ | "127.0.0.1", _ -> callback(socket.Loopback)
    _, Ok(ip_address) -> callback(socket.Address(ip_address))
    _, Error(Nil) ->
      "Invalid interface provided. The value must be a valid IPv4/IPv6 address or \"localhost\""
      |> actor.InitFailed
      |> Error
  }
}

@external(erlang, "pooler_ffi", "parse_address")
fn parse_address(interface: String) -> Result(socket.IpAddress, Nil)

fn try_unix_path(
  path: String,
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case path, string.byte_size(path) {
    "", _ -> Error(actor.InitFailed("Empty unix path is not allowed."))
    _, length if length > 107 ->
      Error(actor.InitFailed("Unix path must not be over 107 bytes limit."))
    path, _length -> {
      case string.contains(does: path, contain: "\u{000000}") {
        True -> Error(actor.InitFailed("Unix containing NUL is not allowed."))
        False -> callback()
      }
    }
  }
}

const default_tls_options = [
  socket.Versions([socket.Tls12, socket.Tls13]),
  socket.HonorCipherOrder(True),
  socket.ClientRenegotiation(False),
]

fn try_tls(
  tls: option.Option(Tls),
  callback: fn(option.Option(List(socket.TlsOption))) ->
    Result(a, actor.StartError),
) {
  case tls {
    option.Some(Tls(certificate:, client_certificates:, alpn:, session_tickets:)) -> {
      use certificate <- try_certificate(certificate)
      use client_certificates <- try_client_certificates(client_certificates)
      use alpn <- try_alpn(alpn)

      let tls_options = [
        socket.CertificateKeys([certificate]),
        socket.SessionTickets(to_internal_ticket_mode(session_tickets)),
        ..client_certificates
      ]

      let tls_options = case alpn {
        [] -> tls_options
        alpn -> [socket.AlpnPreferredProtocols(alpn), ..tls_options]
      }

      callback(option.Some(list.append(default_tls_options, tls_options)))
    }
    option.None -> callback(option.None)
  }
}

fn try_alpn(
  alpn: List(String),
  callback: fn(List(BitArray)) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  list.unique(alpn)
  |> list.try_map(with: fn(protocol) {
    case protocol, string.byte_size(protocol) {
      "", _ -> Error(actor.InitFailed("Empty ALPN protocol provided."))
      _, length if length > 255 ->
        Error(actor.InitFailed(
          "\"" <> protocol <> "\" ALPN protocol exceeded 255 byte limit.",
        ))
      _, _ -> Ok(bit_array.from_string(protocol))
    }
  })
  |> result.try(callback)
}

fn try_certificate(
  tls: Certificate,
  callback: fn(socket.CertificateKey) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case tls {
    Disk(cert:, key:) -> try_disk_certificate(cert, key, option.None, callback)
    EncryptedDisk(cert:, key:, password:) ->
      try_disk_certificate(cert, key, option.Some(password), callback)
    Pem(cert:, key:) -> try_pem_certificate(cert, key, option.None, callback)
    EncryptedPem(cert:, key:, password:) ->
      try_pem_certificate(cert, key, option.Some(password), callback)
    Der(chain:, key:) -> try_der_certificate(chain, key, callback)
  }
}

fn try_disk_certificate(
  certificate_file: String,
  key_file: String,
  password: option.Option(String),
  callback: fn(socket.CertificateKey) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  use certificate <- try_read(certificate_file)
  use key <- try_read(key_file)

  try_pem_certificate(certificate, key, password, callback)
}

fn try_read(
  path: String,
  callback: fn(BitArray) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case file.read(path) {
    Ok(bytes) -> callback(bytes)
    Error(reason) ->
      Error(actor.InitFailed(
        "Could not read "
        <> path
        <> ": "
        <> file.reason_to_string(reason)
        <> ".",
      ))
  }
}

const no_certificate = "No certificate was given. A listener with no certificate accepts connections and then fails every handshake."

fn try_pem_certificate(
  cert: BitArray,
  key: BitArray,
  password: option.Option(String),
  callback: fn(socket.CertificateKey) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case socket.certificates_from_pem(cert) {
    [] -> Error(actor.InitFailed(no_certificate))
    chain ->
      case socket.private_key_from_pem(key, password) {
        Ok(key) -> callback(socket.CertificateChain(chain:, key:))
        Error(pem_error) ->
          Error(actor.InitFailed(
            "Could not read the private key: "
            <> socket.pem_error_to_string(pem_error)
            <> ".",
          ))
      }
  }
}

fn try_der_certificate(
  chain: List(BitArray),
  key: TlsPrivateKey,
  callback: fn(socket.CertificateKey) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case chain {
    [] -> Error(actor.InitFailed(no_certificate))
    chain ->
      callback(socket.CertificateChain(chain:, key: to_internal_key(key)))
  }
}

fn try_client_certificates(
  client_certificates: option.Option(ClientCertificates),
  callback: fn(List(socket.TlsOption)) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case client_certificates {
    option.Some(Requested(trusting:)) ->
      try_trust_store(trusting, False, callback)
    option.Some(Required(trusting:)) ->
      try_trust_store(trusting, True, callback)
    option.None -> callback([])
  }
}

const no_trust_store = "The trust store holds no certificate. There is no authority to check client certificates against, so every client would be rejected."

fn try_trust_store(
  store: TrustStore,
  required: Bool,
  callback: fn(List(socket.TlsOption)) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  let options = [
    socket.Verify(socket.VerifyPeer),
    socket.FailWithoutPeerCertificate(required),
  ]

  case store {
    SystemTrustStore -> {
      let authorities =
        socket.CertificateAuthorities(socket.system_certificate_authorities())
      callback([authorities, ..options])
    }
    TrustDisk(path:) -> {
      use bytes <- try_read(path)
      try_pem_trust_store(bytes, options, callback)
    }
    TrustPem(bytes:) -> try_pem_trust_store(bytes, options, callback)
    TrustDer(certificates:) ->
      case certificates {
        [] -> Error(actor.InitFailed(no_trust_store))
        certificates ->
          callback([socket.CertificateAuthorities(certificates), ..options])
      }
  }
}

fn try_pem_trust_store(
  bytes: BitArray,
  options: List(socket.TlsOption),
  callback: fn(List(socket.TlsOption)) -> Result(a, actor.StartError),
) {
  case socket.certificates_from_pem(bytes) {
    [] -> Error(actor.InitFailed(no_trust_store))
    certificates ->
      callback([socket.CertificateAuthorities(certificates), ..options])
  }
}
