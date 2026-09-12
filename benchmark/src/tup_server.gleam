import gleam/bytes_tree
import gleam/erlang/process
import shared
import tup

pub fn main() {
  let mode = shared.mode()
  let assert Ok(_started) =
    tup.new(
      on_init: fn(_connection, selector) { #(<<>>, selector) },
      handler: fn(connection, buffer, message) {
        case message {
          tup.Incoming(_data) if mode == "sink" -> tup.continue(<<>>)
          tup.Incoming(data) -> {
            let #(count, rest) =
              shared.split_requests(<<buffer:bits, data:bits>>)
            case count {
              0 -> tup.continue(rest)
              _count -> {
                reply(connection, count, mode)
                case mode {
                  "close" -> tup.stop()
                  _keep_open -> tup.continue(rest)
                }
              }
            }
          }
          tup.User(_user) -> tup.continue(buffer)
        }
      },
      on_close: fn(_state) { Nil },
    )
    |> tup.pool_size(shared.pool())
    |> with_buffer(shared.buffer())
    |> tup.listening(on: tup.Tcp("127.0.0.1", shared.port()))
    |> tup.start
  process.sleep_forever()
}

fn reply(connection: tup.Connection, count: Int, mode: String) -> Nil {
  case mode {
    "split" -> {
      let _head = tup.send(connection, bytes_tree.from_bit_array(shared.head()))
      let _body = tup.send(connection, bytes_tree.from_bit_array(shared.body()))
      Nil
    }
    _single_send -> {
      let _sent =
        tup.send(connection, bytes_tree.from_bit_array(shared.response(count)))
      Nil
    }
  }
}

fn with_buffer(builder: tup.Builder(state, message), bytes: Int) {
  case bytes {
    0 -> builder
    bytes -> tup.buffer_size(builder, bytes)
  }
}
