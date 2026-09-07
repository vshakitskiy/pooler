import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import pooler/internals/files
import pooler/socket
import relay_supervisor as relay

pub type Argument {
  Argument(
    address: Address,
    tls: option.Option(socket.CertificateKey),
    active_state: socket.ActiveState,
  )
}

pub type Address {
  Tcp(interface: socket.Interface, port: Int)
  Unix(path: String)
}

pub fn template() {
  relay.Template(start:, child_type: supervision.Worker(shutdown_ms: 5000))
}

fn start(argument: Argument) {
  actor.new_with_initialiser(1000, fn(_self) {
    use <- try_unlink_stale_socket(argument.address)

    let #(port, interface) = case argument.address {
      Tcp(interface:, port:) -> #(port, interface)
      Unix(path:) -> #(0, socket.Local(path))
    }

    let tcp_options = [
      socket.BindAddress(interface),
      socket.Active(argument.active_state),
    ]

    let listen = case argument.tls {
      option.Some(certificate_key) -> {
        let tls_options = [socket.CertificateKeys([certificate_key])]
        socket.listen_tls(port, tcp_options, tls_options)
      }
      option.None -> socket.listen(port, tcp_options)
    }

    case listen {
      Ok(opened) -> {
        actor.initialised(Nil)
        |> actor.returning(opened)
        |> Ok
      }
      Error(error) ->
        Error(
          "Could not open the listen socket: " <> socket.error_to_string(error),
        )
    }
  })
  |> actor.start
}

pub type SocketPathError {
  PathNotSocket(kind: PathKind)
  PathNotInspected(reason: String)
  PathNotRemoved(reason: String)
}

pub type PathKind {
  Device
  Directory
  Regular
  Symlink
  UnknownKind
}

pub fn socket_path_error_to_string(error: SocketPathError) -> String {
  case error {
    PathNotSocket(kind:) ->
      "the path holds "
      <> path_kind_to_string(kind)
      <> " rather than a socket, so it was left untouched"
    PathNotInspected(reason:) ->
      "the path could not be inspected, " <> files.reason_to_string(reason)
    PathNotRemoved(reason:) ->
      "the stale socket could not be removed, "
      <> files.reason_to_string(reason)
  }
}

fn path_kind_to_string(kind: PathKind) -> String {
  case kind {
    Device -> "a device"
    Directory -> "a directory"
    Regular -> "a regular file"
    Symlink -> "a symbolic link"
    UnknownKind -> "a file of a kind these bindings do not name"
  }
}

fn try_unlink_stale_socket(
  address: Address,
  callback: fn() -> Result(a, String),
) -> Result(a, String) {
  case address {
    Unix(path:) -> {
      case unlink_stale_socket(path) {
        Ok(Nil) -> callback()
        Error(error) -> {
          Error(
            "Could not make the unix socket path "
            <> path
            <> " ready to bind: "
            <> socket_path_error_to_string(error),
          )
        }
      }
    }
    Tcp(..) -> callback()
  }
}

@external(erlang, "pooler_ffi", "unlink_stale_socket")
fn unlink_stale_socket(path: String) -> Result(Nil, SocketPathError)
