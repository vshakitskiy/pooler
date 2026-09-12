import gleam/bytes_tree
import gleam/erlang/process
import gleam/option
import glisten
import shared

pub fn main() {
  let mode = shared.mode()
  let assert Ok(_started) =
    glisten.new(
      fn(_connection) { #(<<>>, option.None) },
      fn(buffer, message, connection) {
        case message {
          glisten.Packet(_data) if mode == "sink" -> glisten.continue(<<>>)
          glisten.Packet(data) -> {
            let #(count, rest) =
              shared.split_requests(<<buffer:bits, data:bits>>)
            case count {
              0 -> glisten.continue(rest)
              _count -> {
                reply(connection, count, mode)
                case mode {
                  "close" -> glisten.stop()
                  _keep_open -> glisten.continue(rest)
                }
              }
            }
          }
          glisten.User(_user) -> glisten.continue(buffer)
        }
      },
    )
    |> glisten.with_pool_size(shared.pool())
    |> glisten.bind("127.0.0.1")
    |> glisten.start(shared.port())
  process.sleep_forever()
}

fn reply(connection: glisten.Connection(message), count: Int, mode: String) {
  case mode {
    "split" -> {
      let _head =
        glisten.send(connection, bytes_tree.from_bit_array(shared.head()))
      let _body =
        glisten.send(connection, bytes_tree.from_bit_array(shared.body()))
      Nil
    }
    _single_send -> {
      let _sent =
        glisten.send(
          connection,
          bytes_tree.from_bit_array(shared.response(count)),
        )
      Nil
    }
  }
}
