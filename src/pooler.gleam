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

import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import pooler/internals/files
import pooler/internals/listener
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

pub type Tls {
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

pub fn with_tls(builder: Builder, tls: Tls) -> Builder {
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

  relay.new(fn(children) { add_listener(children, listener_argument) })
  |> relay.start
}

fn add_listener(children: relay.Children(Nil), argument: listener.Argument) {
  relay.child(listener.template())
  |> relay.providing(fn(_nil) { argument })
  |> relay.add(children, _)
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

fn try_tls(
  tls: option.Option(Tls),
  callback: fn(option.Option(socket.CertificateKey)) ->
    Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case tls {
    option.Some(Disk(cert:, key:)) -> try_disk(cert, key, option.None, callback)
    option.Some(EncryptedDisk(cert:, key:, password:)) ->
      try_disk(cert, key, option.Some(password), callback)
    option.Some(Pem(cert:, key:)) -> try_pem(cert, key, option.None, callback)
    option.Some(EncryptedPem(cert:, key:, password:)) ->
      try_pem(cert, key, option.Some(password), callback)
    option.Some(Der(chain:, key:)) -> try_der(chain, key, callback)
    option.None -> callback(option.None)
  }
}

fn try_disk(
  certificate_file: String,
  key_file: String,
  password: option.Option(String),
  callback: fn(option.Option(socket.CertificateKey)) ->
    Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  use certificate <- try_read(certificate_file)
  use key <- try_read(key_file)
  try_pem(certificate, key, password, callback)
}

fn try_read(
  path: String,
  callback: fn(BitArray) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case files.read(path) {
    Ok(bytes) -> callback(bytes)
    Error(reason) ->
      Error(actor.InitFailed(
        "Could not read "
        <> path
        <> ": "
        <> files.reason_to_string(reason)
        <> ".",
      ))
  }
}

const no_certificate = "No certificate was given. A listener with no certificate accepts connections and then fails every handshake."

fn try_pem(
  cert: BitArray,
  key: BitArray,
  password: option.Option(String),
  callback: fn(option.Option(socket.CertificateKey)) ->
    Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case socket.certificates_from_pem(cert) {
    [] -> Error(actor.InitFailed(no_certificate))
    chain ->
      case socket.private_key_from_pem(key, password) {
        Ok(key) -> callback(option.Some(socket.CertificateChain(chain:, key:)))
        Error(pem_error) ->
          Error(actor.InitFailed(
            "Could not read the private key: "
            <> socket.pem_error_to_string(pem_error)
            <> ".",
          ))
      }
  }
}

fn try_der(
  chain: List(BitArray),
  key: TlsPrivateKey,
  callback: fn(option.Option(socket.CertificateKey)) ->
    Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case chain {
    [] -> Error(actor.InitFailed(no_certificate))
    chain ->
      socket.CertificateChain(chain:, key: to_internal_key(key))
      |> option.Some
      |> callback
  }
}
