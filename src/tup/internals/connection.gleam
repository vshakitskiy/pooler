import exception
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import logging
import relay_supervisor as relay
import tup/socket

pub type Relayed(user_state, user_message) {
  Relayed(
    transport: socket.Transport,
    socket: socket.ListenSocket,
    endpoint: socket.Endpoint,
  )
}

pub fn add_child(
  children: relay.Children(Nil),
) -> relay.Children(
  factory.Supervisor(
    Argument(user_state, user_message),
    process.Subject(Message(user_message)),
  ),
) {
  relay.Template(start:, child_type: supervision.Supervisor)
  |> relay.child
  |> relay.providing(fn(_relayed) { Nil })
  |> relay.returning(fn(_relayed, factory) { factory })
  |> relay.add(children, _)
}

pub type Argument(user_state, user_message) {
  Argument(
    transport: socket.Transport,
    socket: socket.Socket,
    acceptor: process.Pid,
    active_state: socket.ActiveState,
    handlers: Handlers(user_state, user_message),
  )
}

pub type Handlers(user_state, user_message) {
  Handlers(
    on_init: fn(Connection, process.Selector(user_message)) ->
      #(user_state, process.Selector(user_message)),
    handler: fn(Connection, user_state, HandlerMessage(user_message)) ->
      Next(user_state, user_message),
    on_close: fn(user_state) -> Nil,
  )
}

pub type Next(user_state, user_message) {
  Continue(
    state: user_state,
    selector: option.Option(process.Selector(user_message)),
    active_state: option.Option(socket.ActiveState),
  )
  NormalStop
  AbnormalStop(reason: String)
}

pub type Connection {
  Connection(
    transport: socket.Transport,
    socket: socket.Socket,
    local: socket.Endpoint,
    peer: socket.Endpoint,
  )
}

pub type HandlerMessage(user_message) {
  Incoming(BitArray)
  UserMessage(user_message)
}

fn start(
  _relayed: Nil,
) -> Result(
  actor.Started(
    factory.Supervisor(
      Argument(user_state, user_message),
      process.Subject(Message(user_message)),
    ),
  ),
  actor.StartError,
) {
  factory.worker_child(start_worker)
  |> factory.restart_strategy(supervision.Temporary)
  |> factory.start
}

pub type Message(user_message) {
  Ready
  AcceptorDown(process.ExitReason)
  Received(socket.Message)
  User(user_message)
}

type State(user_state, user_message) {
  Initialised(
    transport: socket.Transport,
    socket: socket.Socket,
    self: process.Subject(Message(user_message)),
    init_selector: process.Selector(Message(user_message)),
    active_state: socket.ActiveState,
    handlers: Handlers(user_state, user_message),
    monitor: process.Monitor,
  )
  Acknowledged(
    connection: Connection,
    self: process.Subject(Message(user_message)),
    init_selector: process.Selector(Message(user_message)),
    active_state: socket.ActiveState,
    handlers: Handlers(user_state, user_message),
    user_state: user_state,
  )
}

pub fn start_worker(argument: Argument(user_state, user_message)) {
  actor.new_with_initialiser(1000, fn(self) {
    let Argument(transport:, socket:, acceptor:, active_state:, handlers:) =
      argument
    let monitor = process.monitor(acceptor)

    let selector =
      socket.selector(transport)
      |> process.map_selector(Received)
      |> process.select_specific_monitor(monitor, fn(down) {
        AcceptorDown(down.reason)
      })
      |> process.select(self)

    Initialised(
      transport:,
      socket:,
      active_state:,
      self:,
      init_selector: selector,
      handlers:,
      monitor:,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    case state, message {
      Initialised(
        transport:,
        socket:,
        active_state:,
        self:,
        init_selector:,
        handlers:,
        monitor:,
      ),
        Ready
      -> {
        process.demonitor_process(monitor:)

        case socket.handshake(transport, socket, socket.Milliseconds(10_000)) {
          Ok(socket) -> {
            let local = socket.sockname(transport, socket)
            let peer = socket.peername(transport, socket)
            case local, peer {
              Ok(local), Ok(peer) -> {
                use <- refresh_flow_control(transport, socket, active_state)

                let connection = Connection(transport:, socket:, local:, peer:)
                let #(state, user_selector) =
                  handlers.on_init(connection, process.new_selector())

                let selector =
                  process.map_selector(user_selector, User)
                  |> process.merge_selector(init_selector)

                Acknowledged(
                  connection:,
                  self:,
                  init_selector:,
                  active_state:,
                  handlers:,
                  user_state: state,
                )
                |> actor.continue
                |> actor.with_selector(selector)
              }
              _local, _peer ->
                actor.stop_abnormal(
                  "Failed to retrive the sockname and peername during initialisation",
                )
            }
          }
          Error(error) ->
            actor.stop_abnormal(
              "Failed to establish the TLS handshake: "
              <> socket.error_to_string(error),
            )
        }
      }
      Initialised(..), AcceptorDown(_reason) -> actor.stop()
      Initialised(..), _remaining -> {
        logging.log(
          logging.Warning,
          "Unexpected behaviour! Worker under \"Initialised\" received incomming data or user message.",
        )

        actor.continue(state)
      }

      Acknowledged(connection:, active_state:, handlers:, user_state:, ..),
        Received(socket.Incoming(data))
      -> {
        let Connection(transport:, socket:, ..) = connection
        use <- bump_flow_control(transport, socket, active_state)

        let rescued =
          exception.rescue(fn() {
            handlers.handler(connection, user_state, Incoming(data))
          })

        case rescued {
          Ok(next) -> handle_next(state, next)
          Error(exception) -> {
            handlers.on_close(user_state)
            actor.stop_abnormal(exception_to_string(exception))
          }
        }
      }
      Acknowledged(user_state: state, handlers:, ..),
        Received(socket.Disconnected)
      -> {
        handlers.on_close(state)
        actor.stop()
      }
      Acknowledged(user_state: state, handlers:, ..),
        Received(socket.Failed(reason:))
      -> {
        handlers.on_close(state)
        { "Received socket failure: " <> socket.error_to_string(reason) }
        |> actor.stop_abnormal
      }

      Acknowledged(
        connection: Connection(transport:, socket:, ..),
        active_state:,
        ..,
      ),
        Received(socket.Exhausted)
      -> {
        use <- refresh_flow_control(transport, socket, active_state)
        actor.continue(state)
      }
      Acknowledged(connection:, handlers:, user_state:, ..), User(message) -> {
        let rescued =
          exception.rescue(fn() {
            handlers.handler(connection, user_state, UserMessage(message))
          })

        case rescued {
          Ok(next) -> handle_next(state, next)
          Error(exception) -> {
            handlers.on_close(user_state)
            actor.stop_abnormal(exception_to_string(exception))
          }
        }
      }
      Acknowledged(..), _remaining -> actor.continue(state)
    }
  })
  |> actor.start
}

fn bump_flow_control(
  transport: socket.Transport,
  socket: socket.Socket,
  active_state: socket.ActiveState,
  callback: fn() -> actor.Next(a, b),
) {
  case active_state {
    socket.Once ->
      refresh_flow_control(transport, socket, active_state, callback)
    socket.Always | socket.Passive | socket.Packets(..) -> callback()
  }
}

fn refresh_flow_control(
  transport: socket.Transport,
  socket: socket.Socket,
  active_state: socket.ActiveState,
  callback: fn() -> actor.Next(a, b),
) {
  let refresh =
    socket.set_options(transport, socket, [
      socket.Active(active_state),
    ])

  case refresh {
    Ok(Nil) -> callback()
    Error(error) -> {
      { "Failed to follow the flow control: " <> socket.error_to_string(error) }
      |> actor.stop_abnormal
    }
  }
}

fn handle_next(
  state: State(user_state, user_message),
  next: Next(user_state, user_message),
) {
  case state, next {
    Acknowledged(init_selector: selector, ..) as state,
      Continue(state: user_state, selector: user_selector, active_state:)
    -> {
      let state = case active_state {
        option.Some(active_state) ->
          Acknowledged(..state, user_state: user_state, active_state:)
        option.None -> Acknowledged(..state, user_state: user_state)
      }

      let next = actor.continue(state)
      case user_selector {
        option.Some(user_selector) -> {
          process.map_selector(user_selector, User)
          |> process.merge_selector(selector)
          |> actor.with_selector(next, _)
        }
        option.None -> next
      }
    }
    Acknowledged(user_state: state, handlers:, ..), NormalStop -> {
      handlers.on_close(state)
      actor.stop()
    }
    Acknowledged(user_state: state, handlers:, ..), AbnormalStop(reason:) -> {
      handlers.on_close(state)
      actor.stop_abnormal(reason)
    }
    Initialised(..), Continue(..) -> actor.continue(state)
    Initialised(..), NormalStop -> actor.stop()
    Initialised(..), AbnormalStop(reason:) -> actor.stop_abnormal(reason)
  }
}

fn exception_to_string(exception: exception.Exception) {
  case exception {
    exception.Errored(_dynamic) ->
      "An error was raised in the handler. This can be caused by calling the \"echo\", \"panic\", erlang:error/1 function or some other runtime error."
    exception.Thrown(_dynamic) ->
      "A value was thrown in the handler. This can be caused by calling the erlang:throw/1 function."
    exception.Exited(_dynamic) ->
      "A process exited in the handler. This can be caused by calling the erlang:exit/1 function."
  }
}
