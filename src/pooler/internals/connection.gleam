import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import logging
import pooler/internals/listener
import pooler/socket
import relay_supervisor as relay

pub type Relayed(user_state, user_message) {
  Relayed(
    transport: socket.Transport,
    socket: socket.ListenSocket,
    endpoint: socket.Endpoint,
    factory: factory.Supervisor(
      Argument(user_state, user_message),
      process.Subject(Message(user_message)),
    ),
  )
}

pub fn add_child(
  children: relay.Children(listener.Relayed),
) -> relay.Children(Relayed(user_state, user_message)) {
  relay.Template(start:, child_type: supervision.Supervisor)
  |> relay.child
  |> relay.providing(fn(_relayed) { Nil })
  |> relay.returning(fn(relayed, factory) {
    let listener.Relayed(transport:, socket:, endpoint:) = relayed
    Relayed(transport:, socket:, endpoint:, factory:)
  })
  |> relay.add(children, _)
}

pub type Argument(user_state, user_message) {
  Argument(
    transport: socket.Transport,
    socket: socket.Socket,
    server: socket.Endpoint,
    acceptor: process.Pid,
    handlers: Handlers(user_state, user_message),
  )
}

pub type Handlers(user_state, user_message) {
  Handlers(
    on_init: fn(Connection(user_message), process.Selector(user_message)) ->
      #(user_state, process.Selector(user_message)),
    handler: fn(
      Connection(user_message),
      user_state,
      HandlerMessage(user_message),
    ) -> Next(user_state, user_message),
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

pub type Connection(user_message) {
  Connection(
    transport: socket.Transport,
    socket: socket.Socket,
    self: process.Subject(Message(user_message)),
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
    active_state: socket.ActiveState,
    self: process.Subject(Message(user_message)),
    selector: process.Selector(Message(user_message)),
    handlers: Handlers(user_state, user_message),
    server: socket.Endpoint,
    monitor: process.Monitor,
  )
  Acknowledged(
    transport: socket.Transport,
    socket: socket.Socket,
    active_state: socket.ActiveState,
    self: process.Subject(Message(user_message)),
    selector: process.Selector(Message(user_message)),
    handlers: Handlers(user_state, user_message),
    server: socket.Endpoint,
    state: user_state,
    client: socket.Endpoint,
  )
}

pub fn start_worker(argument: Argument(user_state, user_message)) {
  actor.new_with_initialiser(1000, fn(self) {
    let Argument(transport:, socket:, server:, acceptor:, handlers:) = argument
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
      active_state: socket.Once,
      self:,
      selector:,
      handlers:,
      server:,
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
        selector:,
        handlers:,
        server:,
        monitor:,
      ),
        Ready
      -> {
        process.demonitor_process(monitor:)

        case socket.handshake(transport, socket, socket.Milliseconds(10_000)) {
          Ok(socket) -> {
            case socket.peername(transport, socket) {
              Ok(client) -> {
                use <- refresh_flow_control(transport, socket, active_state)

                let connection = Connection(transport:, socket:, self:)
                let #(state, user_selector) =
                  handlers.on_init(connection, process.new_selector())

                let updated_selector =
                  process.map_selector(user_selector, User)
                  |> process.merge_selector(selector)

                Acknowledged(
                  transport:,
                  socket:,
                  active_state:,
                  self:,
                  selector:,
                  state:,
                  handlers:,
                  server:,
                  client:,
                )
                |> actor.continue
                |> actor.with_selector(updated_selector)
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

      Acknowledged(
        transport:,
        socket:,
        active_state:,
        self:,
        selector: _,
        handlers:,
        server: _,
        state: user_state,
        client: _,
      ),
        Received(socket.Incoming(data))
      -> {
        use <- bump_flow_control(transport, socket, active_state)

        let connection = Connection(transport:, socket:, self:)
        // TODO: rescue
        handlers.handler(connection, user_state, Incoming(data))
        |> handle_next(state, _)
      }
      Acknowledged(state:, handlers:, ..), Received(socket.Disconnected) -> {
        handlers.on_close(state)
        actor.stop()
      }
      Acknowledged(state:, handlers:, ..), Received(socket.Failed(reason:)) -> {
        handlers.on_close(state)
        { "Received socket failure: " <> socket.error_to_string(reason) }
        |> actor.stop_abnormal
      }

      Acknowledged(transport:, socket:, active_state:, ..),
        Received(socket.Exhausted)
      -> {
        use <- refresh_flow_control(transport, socket, active_state)
        actor.continue(state)
      }
      Acknowledged(transport:, socket:, self:, handlers:, state: user_state, ..),
        User(message)
      -> {
        let connection = Connection(transport:, socket:, self:)
        // TODO: rescue
        handlers.handler(connection, user_state, UserMessage(message))
        |> handle_next(state, _)
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
    Acknowledged(selector:, ..) as state,
      Continue(state: user_state, selector: user_selector, active_state:)
    -> {
      let state = case active_state {
        option.Some(active_state) ->
          Acknowledged(..state, state: user_state, active_state:)
        option.None -> Acknowledged(..state, state: user_state)
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
    Acknowledged(state:, handlers:, ..), NormalStop -> {
      handlers.on_close(state)
      actor.stop()
    }
    Acknowledged(state:, handlers:, ..), AbnormalStop(reason:) -> {
      handlers.on_close(state)
      actor.stop_abnormal(reason)
    }
    _, Continue(..) -> actor.continue(state)
    _, NormalStop -> actor.stop()
    _, AbnormalStop(reason:) -> actor.stop_abnormal(reason)
  }
}
