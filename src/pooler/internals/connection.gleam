import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import logging
import pooler/internals/listener
import pooler/socket
import relay_supervisor as relay

pub type Relayed(user_message) {
  Relayed(
    transport: socket.Transport,
    socket: socket.ListenSocket,
    endpoint: socket.Endpoint,
    factory: factory.Supervisor(
      Argument,
      process.Subject(Message(user_message)),
    ),
  )
}

pub fn add_child(
  children: relay.Children(listener.Relayed),
) -> relay.Children(Relayed(user_message)) {
  relay.Template(start:, child_type: supervision.Supervisor)
  |> relay.child
  |> relay.providing(fn(_relayed) { Nil })
  |> relay.returning(fn(relayed, factory) {
    let listener.Relayed(transport:, socket:, endpoint:) = relayed
    Relayed(transport:, socket:, endpoint:, factory:)
  })
  |> relay.add(children, _)
}

pub type Argument {
  Argument(
    transport: socket.Transport,
    socket: socket.Socket,
    server: socket.Endpoint,
    acceptor: process.Pid,
  )
}

fn start(
  _relayed: Nil,
) -> Result(
  actor.Started(
    factory.Supervisor(Argument, process.Subject(Message(user_message))),
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

type State(user_message) {
  Initialised(
    transport: socket.Transport,
    socket: socket.Socket,
    self: process.Subject(Message(user_message)),
    server: socket.Endpoint,
    monitor: process.Monitor,
  )
  Acknowledged(
    transport: socket.Transport,
    socket: socket.Socket,
    self: process.Subject(Message(user_message)),
    server: socket.Endpoint,
    client: socket.Endpoint,
  )
}

pub fn start_worker(argument: Argument) {
  actor.new_with_initialiser(1000, fn(self) {
    let Argument(transport:, socket:, server:, acceptor:) = argument
    let monitor = process.monitor(acceptor)

    let selector =
      socket.selector(transport)
      |> process.map_selector(Received)
      |> process.select_specific_monitor(monitor, fn(down) {
        AcceptorDown(down.reason)
      })
      |> process.select(self)

    Initialised(transport:, socket:, self:, server:, monitor:)
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    case state, message {
      Initialised(transport:, socket:, self:, server:, monitor:), Ready -> {
        process.demonitor_process(monitor:)

        case socket.handshake(transport, socket, socket.Milliseconds(10_000)) {
          Ok(socket) -> {
            case socket.peername(transport, socket) {
              Ok(client) -> {
                use <- refresh_flow_control(transport, socket, socket.Once)

                Acknowledged(transport:, socket:, self:, server:, client:)
                |> actor.continue
              }
              Error(_error) ->
                actor.stop_abnormal(
                  "Failed to retrive the peername during initialisation",
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
          logging.Alert,
          "Unexpected behaviour! Worker under \"Initialised\" received incomming data or user message.",
        )

        actor.continue(state)
      }

      Acknowledged(transport:, socket:, self:, server:, client:),
        Received(socket.Incoming(data))
      -> {
        use <- bump_flow_control(transport, socket, socket.Once)

        echo data as "received!"
        // TODO: some handler function blablabla

        actor.continue(state)
      }
      Acknowledged(..), Received(socket.Disconnected) -> {
        // TODO: on_close? 
        actor.stop()
      }
      Acknowledged(..), Received(socket.Failed(reason:)) ->
        { "Received socket failure: " <> socket.error_to_string(reason) }
        |> actor.stop_abnormal

      Acknowledged(transport:, socket:, ..), Received(socket.Exhausted) -> {
        use <- refresh_flow_control(transport, socket, socket.Once)
        actor.continue(state)
      }
      Acknowledged(transport:, socket:, ..), User(message) -> {
        use <- bump_flow_control(transport, socket, socket.Once)

        echo message as "user message!"
        // TODO: some handler function blablabla

        actor.continue(state)
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
