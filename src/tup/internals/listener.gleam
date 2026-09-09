import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import relay_supervisor as relay
import tup/internals/file
import tup/socket

pub type Argument {
  Argument(address: Address, tls: option.Option(List(socket.TlsOption)))
}

pub type Relayed {
  Relayed(
    transport: socket.Transport,
    socket: socket.ListenSocket,
    endpoint: socket.Endpoint,
  )
}

pub type Address {
  Tcp(interface: socket.Interface, port: Int)
  Unix(path: String)
}

pub fn add_child(children: relay.Children(Nil), argument: Argument) {
  relay.Template(start:, child_type: supervision.Worker(shutdown_ms: 5000))
  |> relay.child
  |> relay.providing(fn(_nil) { argument })
  |> relay.add(children, _)
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
      socket.Active(socket.Passive),
      socket.SendTimeout(socket.Milliseconds(30_000)),
      socket.ReuseAddress(True),
      socket.SendTimeoutClose(True),
    ]

    let listen = case argument.tls {
      option.Some(tls_options) ->
        socket.listen_tls(port, tcp_options, tls_options)
      option.None -> socket.listen(port, tcp_options)
    }

    case listen {
      Ok(#(transport, socket)) -> {
        case socket.sockname_listener(transport, socket) {
          Ok(endpoint) -> {
            actor.initialised(Nil)
            |> actor.returning(Relayed(transport:, socket:, endpoint:))
            |> Ok
          }
          Error(error) ->
            Error(
              "Could not retrieve sockname: " <> socket.error_to_string(error),
            )
        }
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
      "the path could not be inspected, " <> file.reason_to_string(reason)
    PathNotRemoved(reason:) ->
      "the stale socket could not be removed, " <> file.reason_to_string(reason)
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

@external(erlang, "tup_ffi", "unlink_stale_socket")
fn unlink_stale_socket(path: String) -> Result(Nil, SocketPathError)
