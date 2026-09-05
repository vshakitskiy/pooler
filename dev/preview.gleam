import gleam/io
import logging
import pooler

pub fn main() -> Nil {
  logging.configure()

  let _ =
    pooler.new()
    |> pooler.listening(on: pooler.Unix(path: "/tmp/pooler.sock"))
    |> pooler.start
    |> echo

  io.println("Hello from pooler!")
}
