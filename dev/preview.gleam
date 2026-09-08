import gleam/erlang/process
import gleam/int
import logging
import pooler

pub fn main() -> Nil {
  logging.set_level(logging.Debug)
  logging.configure()

  let subject = process.new_subject()

  let assert Ok(_started) =
    pooler.new(
      on_init: fn(_connection, selector) {
        let self = process.new_subject()
        process.send(subject, self)
        #(1, process.select(selector, self))
      },
      handler: fn(_connection, state, message) {
        echo message
          as { "Incomming message! (" <> int.to_string(state) <> ")" }
        pooler.continue(state + 1)
      },
      on_close: fn(state) {
        echo "Connection closed! (" <> int.to_string(state) <> ")"
        Nil
      },
    )
    |> pooler.listening(on: pooler.Tcp(interface: "127.0.0.1", port: 3000))
    |> pooler.start

  let subject = process.receive_forever(subject)
  process.send(subject, 10_278)

  process.sleep_forever()
}
