import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import relay_supervisor as relay
import tup/internals/connection
import tup/internals/file
import tup/internals/listener
import tup/internals/pool
import tup/socket

/// An IPv4 or IPv6 address.
pub type IpAddress {
  /// Four octets.
  Ipv4(Int, Int, Int, Int)
  /// Eight 16 bit groups.
  Ipv6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub fn ip_address_to_string(address: IpAddress) {
  to_socket_ip_address(address)
  |> socket.ip_address_to_string
}

/// Extracts the IPv4 address inside an IPv4 mapped IPv6 address.
/// 
/// ```gleam
/// unmap_ipv4(Ipv6(0, 0, 0, 0, 0, 0xffff, 0x7f00, 0x0001))
/// // -> Ipv4(127, 0, 0, 1)
/// ```
pub fn unmap_ipv4(address: IpAddress) -> IpAddress {
  case address {
    Ipv6(0, 0, 0, 0, 0, 0xffff, high, low) ->
      Ipv4(
        int.bitwise_shift_right(high, 8),
        int.bitwise_and(high, 0xff),
        int.bitwise_shift_right(low, 8),
        int.bitwise_and(low, 0xff),
      )
    Ipv4(..) | Ipv6(..) -> address
  }
}

fn from_socket_ip_address(address: socket.IpAddress) {
  case address {
    socket.Ipv4(a, b, c, d) -> Ipv4(a, b, c, d)
    socket.Ipv6(a, b, c, d, e, f, g, h) -> Ipv6(a, b, c, d, e, f, g, h)
  }
}

fn to_socket_ip_address(address: IpAddress) {
  case address {
    Ipv4(a, b, c, d) -> socket.Ipv4(a, b, c, d)
    Ipv6(a, b, c, d, e, f, g, h) -> socket.Ipv6(a, b, c, d, e, f, g, h)
  }
}

pub opaque type Connection {
  Connection(
    transport: socket.Transport,
    socket: socket.Socket,
    local: Endpoint,
    peer: Endpoint,
  )
}

fn from_internal_connection(connection: connection.Connection) -> Connection {
  case connection {
    connection.Connection(transport:, socket:, local:, peer:) ->
      Connection(
        transport:,
        socket:,
        local: from_socket_endpoint(local),
        peer: from_socket_endpoint(peer),
      )
  }
}

pub fn socket(connection: Connection) {
  #(connection.transport, connection.socket)
}

pub type Endpoint {
  /// An address and a port on a TCP socket.
  TcpEndpoint(ip_address: IpAddress, port: Int)
  /// The path of a Unix domain socket.
  UnixEndpoint(path: String)
}

pub fn endpoint_to_string(endpoint: Endpoint) {
  to_socket_endpoint(endpoint)
  |> socket.endpoint_to_string
}

fn from_socket_endpoint(endpoint: socket.Endpoint) -> Endpoint {
  case endpoint {
    socket.TcpEndpoint(ip_address:, port:) ->
      TcpEndpoint(ip_address: from_socket_ip_address(ip_address), port:)
    socket.UnixEndpoint(path:) -> UnixEndpoint(path:)
  }
}

fn to_socket_endpoint(endpoint: Endpoint) -> socket.Endpoint {
  case endpoint {
    TcpEndpoint(ip_address:, port:) ->
      socket.TcpEndpoint(ip_address: to_socket_ip_address(ip_address), port:)
    UnixEndpoint(path:) -> socket.UnixEndpoint(path:)
  }
}

pub fn peer(connection: Connection) {
  connection.peer
}

pub fn local(connection: Connection) {
  connection.local
}

pub fn send(connection: Connection, data: bytes_tree.BytesTree) {
  socket.send(connection.transport, connection.socket, data)
}

pub fn socket_error_to_string(error: socket.SocketError) {
  socket.error_to_string(error)
}

pub opaque type Next(user_state, user_message) {
  Continue(
    state: user_state,
    selector: option.Option(process.Selector(user_message)),
    active_state: option.Option(socket.ActiveState),
  )
  NormalStop
  AbnormalStop(reason: String)
}

pub fn continue(state: user_state) {
  Continue(state:, selector: option.None, active_state: option.None)
}

pub fn with_selector(
  next: Next(user_state, user_message),
  selector: process.Selector(user_message),
) {
  case next {
    Continue(..) as next -> Continue(..next, selector: option.Some(selector))
    remaining -> remaining
  }
}

pub fn with_active_state(
  next: Next(user_state, user_message),
  active_state: ActiveState,
) {
  case next {
    Continue(..) as next ->
      Continue(
        ..next,
        active_state: option.Some(to_socket_active_state(active_state)),
      )
    remaining -> remaining
  }
}

pub fn stop() {
  NormalStop
}

pub fn stop_abnormal(reason: String) {
  AbnormalStop(reason:)
}

fn to_internal_next(
  next: Next(user_state, user_message),
) -> connection.Next(user_state, user_message) {
  case next {
    Continue(state:, selector:, active_state:) ->
      connection.Continue(state:, selector:, active_state:)
    NormalStop -> connection.NormalStop
    AbnormalStop(reason:) -> connection.AbnormalStop(reason:)
  }
}

pub type Message(user_message) {
  Incoming(BitArray)
  User(user_message)
}

fn from_internal_message(
  message: connection.HandlerMessage(user_message),
) -> Message(user_message) {
  case message {
    connection.Incoming(data) -> Incoming(data)
    connection.UserMessage(message) -> User(message)
  }
}

pub opaque type Builder(user_state, user_message) {
  Builder(
    address: Address,
    tls: option.Option(Tls),
    active_state: socket.ActiveState,
    pool_size: Int,
    handlers: connection.Handlers(user_state, user_message),
  )
}

pub fn new(
  on_init on_init: fn(Connection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler handler: fn(Connection, user_state, Message(user_message)) ->
    Next(user_state, user_message),
  on_close on_close: fn(user_state) -> Nil,
) -> Builder(user_state, user_message) {
  Builder(
    address: Tcp(interface: "127.0.0.1", port: 3000),
    tls: option.None,
    active_state: socket.Once,
    pool_size: 20,
    handlers: connection.Handlers(
      on_init: fn(connection, selector) {
        let connection = from_internal_connection(connection)
        on_init(connection, selector)
      },
      handler: fn(connection, state, message) {
        let connection = from_internal_connection(connection)
        let message = from_internal_message(message)
        handler(connection, state, message)
        |> to_internal_next
      },
      on_close:,
    ),
  )
}

pub fn pool_size(builder: Builder(user_state, user_message), pool_size: Int) {
  Builder(..builder, pool_size:)
}

pub type Address {
  Tcp(interface: String, port: Int)
  Unix(path: String)
}

pub fn listening(
  builder: Builder(user_state, user_message),
  on address: Address,
) {
  Builder(..builder, address:)
}

pub type ActiveState {
  Once
  Count(n: Int)
  Active
}

fn to_socket_active_state(active_state: ActiveState) -> socket.ActiveState {
  case active_state {
    Once -> socket.Once
    Count(n:) -> socket.Packets(count: n)
    Active -> socket.Always
  }
}

pub fn active_state(
  builder: Builder(user_state, user_message),
  active_state: ActiveState,
) {
  Builder(..builder, active_state: to_socket_active_state(active_state))
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

pub fn with_tls(builder: Builder(user_state, user_message), tls: Tls) {
  Builder(..builder, tls: option.Some(tls))
}

pub fn supervised(builder: Builder(user_state, user_message)) {
  use <- supervision.supervisor
  start(builder)
}

pub fn start(builder: Builder(user_state, user_message)) {
  let Builder(address:, tls:, active_state:, pool_size:, handlers:) = builder

  use pool_size <- try_pool_size(pool_size)

  use address <- result.try(case address {
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
  use tls <- try_tls(tls)

  let listener_argument = listener.Argument(address:, tls:)
  let pool_argument = pool.Argument(pool_size:, active_state:, handlers:)

  // The current supervision tree design is:
  //
  // ┆
  // ┆
  // └─ Root Supervisor, RestForOne outer relay_supervisor
  //    ├─ Connection Supervisor, OneForOne Transient factory_supervisor
  //    │  └─ Spawned Connection, worker N
  //    └─ Inner relay, RestForOne inner relay_supervisor
  //       ├─ Listener, worker
  //       └─ Acceptor Pool, OneForOne static_supervisor
  //         ├─ Acceptor, worker 1
  //         ├─ Acceptor, worker 2
  //         ┆
  //         ┆
  //         └─ Acceptor, worker N
  //
  // At the time of writing the documentation lines, current implementation 
  // provides these solutions over Glisten:
  //
  // - There is no enforced process naming in Tup. Relay supervisors allows the 
  //   children to accept and return arguments to the next children in the order.
  //   *However*! This comes with a small tradeoff. Relay supervisors are using 
  //   RestForOne strategies. On a connection supervisor restart the restart 
  //   cascased through the inner relay and the listen socket is reopened. 
  //   Glisten's acceptor uses a name for referencing its connection supervisor 
  //   and allows each child survive the restarts without touching the port. 
  //
  // - Accept errors are handled properly. Glisten kills the acceptor on any 
  //   accept error. In Tup I decided that on Closed or Einval we can stop 
  //   normally, on Emfile or Enfile it's better to wait some time, around 100ms.
  //   On Timeout or Econnaborted there is no reason to abnormally crash, just
  //   continue looping over the acceptor.
  //   
  //   This matters most under descriptor exhaustion. Glisten treats Emfile as
  //   abnormal and its acceptors are Permanent so every acceptor crashes and
  //   is restarted straight back into the same error until the pool supervisor
  //   reaches its restart intensity and dies.
  //
  // - Any handoff race is pretty much resolved. Glisten's connection waits for
  //   Ready with no monitor or timeout, so an acceptor dying mid handoff leaks
  //   a connection process or, in the worst timing when acceptor died after 
  //   transfering socket controls, a fd. Tup monitors the acceptor and 
  //   demonitors on Ready.
  //
  // - The shutdown order is changed. Glisten kills the connections first while
  //   acceptors still accept and the port is still open. This can create a 
  //   scenario during the shutdown phase when the connections are accepted, 
  //   leading them to fail. Tup kills acceptor and socket first and only after 
  //   that deals with connections.
  //
  // - Glisten has no timeout on accepting the connection. It may seem okay at
  //   first but there is no way to use the tracing and debugging features in
  //   OTP that actor abstraction provides while the accept is infinitely 
  //   waiting for the new connection. Tup has 30 seconds accept timeout that 
  //   can at least provide some interval for reading incomming OTP messages.
  //
  relay.new(fn(children) {
    connection.add_child(children)
    |> pool.add_child(listener_argument, pool_argument)
  })
  |> relay.start
}

fn try_pool_size(
  pool_size: Int,
  callback: fn(Int) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case pool_size {
    pool_size if pool_size <= 0 ->
      Error(actor.InitFailed("Provided pool size is negative or equals to 0."))
    pool_size -> callback(pool_size)
  }
}

fn try_port(
  port: Int,
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case port {
    port if port < 0 || port > 65_535 ->
      Error(actor.InitFailed("Port provided outside of a 0..65535 window."))
    _port -> callback()
  }
}

fn try_interface(
  interface: String,
  callback: fn(socket.Interface) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case interface, parse_address(interface) {
    "0.0.0.0", _parsed -> callback(socket.Any)
    "localhost", _parsed | "127.0.0.1", _parsed -> callback(socket.Loopback)
    _interface, Ok(ip_address) -> callback(socket.Address(ip_address))
    _interface, Error(Nil) ->
      "Invalid interface provided. The value must be a valid IPv4/IPv6 address or \"localhost\""
      |> actor.InitFailed
      |> Error
  }
}

@external(erlang, "tup_ffi", "parse_address")
fn parse_address(interface: String) -> Result(socket.IpAddress, Nil)

fn try_unix_path(
  path: String,
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  // TODO: a unix path that exists but isn't a socket, for example Unix("/tmp"), 
  // kills the caller instead of returning an Error.
  case path, string.byte_size(path) {
    "", _length -> Error(actor.InitFailed("Empty unix path is not allowed."))
    _path, length if length > 107 ->
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
      "", _length -> Error(actor.InitFailed("Empty ALPN protocol provided."))
      _protocol, length if length > 255 ->
        Error(actor.InitFailed(
          "\"" <> protocol <> "\" ALPN protocol exceeded 255 byte limit.",
        ))
      _protocol, _length -> Ok(bit_array.from_string(protocol))
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
