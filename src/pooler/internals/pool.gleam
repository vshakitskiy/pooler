import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import logging
import pooler/internals/connection
import pooler/socket
import relay_supervisor as relay

pub fn add_child(
  children: relay.Children(connection.Relayed(user_state, user_message)),
  pool_size pool_size: Int,
  handlers handlers: connection.Handlers(user_state, user_message),
) {
  relay.Template(start:, child_type: supervision.Supervisor)
  |> relay.child
  |> relay.providing(fn(relayed) { #(relayed, pool_size, handlers) })
  |> relay.returning(fn(_argument, _supervisor) { Nil })
  |> relay.add(children, _)
}

fn start(
  argument: #(
    connection.Relayed(user_state, user_message),
    Int,
    connection.Handlers(user_state, user_message),
  ),
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let #(relayed, pool_size, handlers) = argument

  supervisor.new(supervisor.OneForOne)
  |> int.range(from: 0, to: pool_size, with: _, run: fn(supervisor, _index) {
    supervision.worker(fn() { start_worker(relayed, handlers) })
    |> supervisor.add(supervisor, _)
  })
  |> supervisor.start
}

type Message {
  Accept
}

type State(user_state, user_message) {
  State(
    transport: socket.Transport,
    socket: socket.ListenSocket,
    endpoint: socket.Endpoint,
    factory: factory.Supervisor(
      connection.Argument(user_state, user_message),
      process.Subject(connection.Message(user_message)),
    ),
    pid: process.Pid,
    self: process.Subject(Message),
    handlers: connection.Handlers(user_state, user_message),
  )
}

fn start_worker(
  relayed: connection.Relayed(user_state, user_message),
  handlers: connection.Handlers(user_state, user_message),
) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Accept)

    let connection.Relayed(transport:, socket:, endpoint:, factory:) = relayed
    State(
      transport:,
      socket:,
      endpoint:,
      factory:,
      pid: process.self(),
      self:,
      handlers:,
    )
    |> actor.initialised
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(fn(state, _message) {
    let State(transport:, socket:, endpoint:, factory:, pid:, ..) = state

    case socket.accept(transport, socket, socket.Milliseconds(30_000)) {
      Ok(socket) -> {
        let argument =
          connection.Argument(
            transport:,
            socket:,
            server: endpoint,
            acceptor: pid,
            handlers:,
          )
        case factory.start_child(factory, argument) {
          Ok(actor.Started(pid:, data:)) -> {
            case socket.controlling_process(transport, socket, pid) {
              Ok(Nil) -> {
                process.send(data, connection.Ready)
                loop(state)
              }
              Error(error) -> {
                actor.stop_abnormal(
                  "Failed to transfer socket ownership: "
                  <> socket.error_to_string(error),
                )
              }
            }
          }
          Error(error) ->
            actor.stop_abnormal(
              "Failed to start a connection worker: "
              <> actor_start_error_to_string(error),
            )
        }
      }

      Error(socket.Timeout) | Error(socket.Econnaborted) -> loop(state)
      Error(socket.Closed) | Error(socket.Einval) -> actor.stop()
      Error(socket.Emfile as error) | Error(socket.Enfile as error) -> {
        { "Failed to accept the connection: " <> socket.error_to_string(error) }
        |> logging.log(logging.Error, _)

        loop_after(state, 100)
      }
      Error(error) ->
        { "Failed to accept the connection: " <> socket.error_to_string(error) }
        |> actor.stop_abnormal
    }
  })
  |> actor.start
}

fn loop(state: State(user_state, user_message)) {
  process.send(state.self, Accept)
  actor.continue(state)
}

fn loop_after(state: State(user_state, user_message), milliseconds: Int) {
  process.send_after(state.self, milliseconds, Accept)
  actor.continue(state)
}

fn actor_start_error_to_string(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "timeout"
    actor.InitFailed(reason) ->
      "initialisation process failed with reason \"" <> reason <> "\""
    actor.InitExited(process.Normal) -> "initialisation process exited normally"
    actor.InitExited(process.Killed) -> "initialisation process was killed"
    actor.InitExited(process.Abnormal(reason: _)) ->
      "initialisation process was killed abnormally!"
  }
}
