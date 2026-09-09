import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import logging
import tup

pub fn main() -> Nil {
  logging.set_level(logging.Debug)
  logging.configure()

  let subject = process.new_subject()

  let assert Ok(_started) =
    tup.new(
      on_init: fn(_connection, selector) {
        let self = process.new_subject()
        process.send(subject, self)
        #(1, process.select(selector, self))
      },
      handler: fn(connection, state, message) {
        echo message
          as { "Incomming message! (" <> int.to_string(state) <> ")" }
        let data = case message {
          tup.Incoming(data) -> bytes_tree.from_bit_array(data)
          tup.User(integer) -> bytes_tree.from_bit_array(<<integer>>)
        }
        case tup.send(connection, data) {
          Ok(Nil) -> tup.continue(state + 1)
          Error(socket) -> tup.stop_abnormal(tup.socket_error_to_string(socket))
        }
      },
      on_close: fn(state) {
        echo "Connection closed! (" <> int.to_string(state) <> ")"
        Nil
      },
    )
    |> tup.listening(on: tup.Tcp(interface: "127.0.0.1", port: 3000))
    |> tup.start

  let subject = process.receive_forever(subject)
  process.send(subject, 10_278)

  process.sleep_forever()
}
