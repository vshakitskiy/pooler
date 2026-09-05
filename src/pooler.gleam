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

import gleam/io
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import pooler/internals/listener
import pooler/socket
import relay_supervisor as relay

pub opaque type Builder {
  Builder(address: Address, active_state: socket.ActiveState, pool_size: Int)
}

pub type Address {
  Tcp(interface: String, port: Int)
  Unix(path: String)
}

pub fn new() -> Builder {
  Builder(
    address: Tcp(interface: "127.0.0.1", port: 3000),
    active_state: socket.Once,
    pool_size: 20,
  )
}

pub fn listening(builder: Builder, on address: Address) {
  Builder(..builder, address:)
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

  let listener_argument =
    listener.Argument(address:, active_state: builder.active_state)

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
    _, Error(Nil) -> {
      logging.log(logging.Warning, "Invalid interface provided!")

      "Invalid interface provided. The value must be a valid IPv4/IPv6 address or \"localhost\""
      |> actor.InitFailed
      |> Error
    }
  }
}

@external(erlang, "pooler_ffi", "parse_address")
fn parse_address(interface: String) -> Result(socket.IpAddress, Nil)

fn try_unix_path(
  path: String,
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case path, string.byte_size(path) {
    "", _ -> {
      logging.log(logging.Warning, "Empty unix path provided!")
      Error(actor.InitFailed("Empty unix path is not allowed."))
    }
    _, length if length > 107 -> {
      logging.log(logging.Warning, "Unix path is over limited size!")
      Error(actor.InitFailed("Unix path must not be over 107 bytes limit."))
    }
    path, _length -> {
      case string.contains(does: path, contain: "\u{000000}") {
        True -> {
          logging.log(logging.Warning, "Unix path contains NUL!")
          Error(actor.InitFailed("Unix containing NUL is not allowed."))
        }
        False -> callback()
      }
    }
  }
}
