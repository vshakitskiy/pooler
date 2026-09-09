import gleam/erlang/process
import gleam/function
import gleam/otp/actor
import gleam/otp/supervision
import relay_supervisor as relay
import tup/internals/pool
import tup/socket

pub fn add_child(
  children: relay.Children(pool.Relayed),
) -> relay.Children(Nil) {
  relay.Template(start:, child_type: supervision.Worker(shutdown_ms: 5000))
  |> relay.child
  |> relay.providing(function.identity)
  |> relay.returning(fn(_relayed, _returning) { Nil })
  |> relay.add(children, _)
}

pub type Message {
  Exit(process.ExitMessage)
}

pub type State {
  State(transport: socket.Transport, socket: socket.ListenSocket)
}

fn start(
  relayed: pool.Relayed,
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(1000, fn(_self) {
    process.trap_exits(True)

    let selector =
      process.new_selector()
      |> process.select_trapped_exits(Exit)

    let pool.Relayed(transport:, socket:) = relayed
    actor.initialised(State(transport:, socket:))
    |> actor.selecting(selector)
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(fn(state, _message) {
    let State(transport:, socket:) = state

    case socket.close_listener(transport, socket) {
      Ok(Nil) -> actor.stop()
      Error(error) ->
        actor.stop_abnormal(
          "Failed to close the socket listener: "
          <> socket.error_to_string(error),
        )
    }
  })
  |> actor.start
}
