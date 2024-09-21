import gleam/bytes_builder
import gleam/erlang/process
import gleam/function
import gleam/list
import gleam/option
import gleam/otp/actor
import glisten.{Packet}

type Message {
  Connect(glisten.Connection(bytes_builder.BytesBuilder))
  Disconnect(glisten.Connection(bytes_builder.BytesBuilder))
  Body(
    bytes_builder.BytesBuilder,
    glisten.Connection(bytes_builder.BytesBuilder),
  )
}

fn publish_loop(
  message: Message,
  connections: List(glisten.Connection(bytes_builder.BytesBuilder)),
) {
  case message {
    Connect(new_connection) -> {
      [new_connection, ..connections] |> actor.continue
    }
    Disconnect(removed_connection) -> {
      connections
      |> list.filter(fn(cnxn) { cnxn != removed_connection })
      |> actor.continue
    }
    Body(body, sender) -> {
      connections
      |> list.filter(fn(cnxn) { cnxn != sender })
      |> list.each(fn(cnxn) { glisten.send(cnxn, body) })
      connections |> actor.continue
    }
  }
}

pub fn main() {
  let assert Ok(pubber) = actor.start([], publish_loop)

  let assert Ok(_) =
    glisten.handler(
      fn(connection) {
        let subj = process.new_subject()
        process.send(pubber, Connect(connection))
        let selector =
          process.new_selector()
          |> process.selecting(subj, function.identity)
        #(Nil, option.Some(selector))
      },
      fn(msg, state, conn) {
        let assert Packet(msg) = msg
        actor.send(pubber, Body(bytes_builder.from_bit_array(msg), conn))
        actor.continue(state)
      },
    )
    |> glisten.serve(3000)

  process.sleep_forever()
}
