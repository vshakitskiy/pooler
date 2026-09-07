import gleam/erlang/process
import gleam/io
import logging
import pooler

pub fn main() -> Nil {
  logging.configure()

  echo pooler.new()
    |> pooler.listening(on: pooler.Tcp(interface: "127.0.0.1", port: 3000))
    |> pooler.start

  io.println("Hello from pooler!")

  process.sleep_forever()
}
