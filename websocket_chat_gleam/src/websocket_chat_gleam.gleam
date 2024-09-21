import gleam/bytes_builder
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import mist

type ChatMessage {
  Connect(mist.WebsocketConnection)
  Disconnect(mist.WebsocketConnection)
  Body(String, mist.WebsocketConnection)
}

fn distributor(
  message: ChatMessage,
  connections: List(mist.WebsocketConnection),
) {
  case message {
    Connect(sel) -> {
      [sel, ..connections] |> actor.continue
    }
    Disconnect(sel) -> {
      connections |> list.filter(fn(s) { s != sel }) |> actor.continue
    }
    Body(body, sender) -> {
      connections
      |> list.filter(fn(s) { s != sender })
      |> list.each(fn(conn) { mist.send_text_frame(conn, body) })
      connections |> actor.continue
    }
  }
}

type WsMessageHandlerState {
  State(distributor: process.Subject(ChatMessage))
}

fn handle_ws_message(
  state,
  conn: mist.WebsocketConnection,
  msg: mist.WebsocketMessage(b),
) {
  let State(dist) = state
  case msg {
    mist.Text(body) -> {
      process.send(dist, Body(body, conn))
      state |> actor.continue
    }
    mist.Custom(_) | mist.Binary(_) -> {
      state |> actor.continue
    }
    mist.Closed | mist.Shutdown -> {
      process.send(dist, Disconnect(conn))
      actor.Stop(process.Normal)
    }
  }
}

pub fn main() {
  let assert Ok(dist) = actor.start([], distributor)

  let selector = process.new_selector()

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_builder.new()))

  let assert Ok(_) =
    fn(req: request.Request(mist.Connection)) -> response.Response(
      mist.ResponseData,
    ) {
      case request.path_segments(req) {
        [] -> {
          mist.websocket(
            request: req,
            on_init: fn(conn) {
              process.send(dist, Connect(conn))
              #(State(dist), option.Some(selector))
            },
            on_close: fn(_state) { io.println("disconnected??") },
            handler: handle_ws_message,
          )
        }
        _ -> not_found
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.with_ipv6
    |> mist.port(8080)
    |> mist.start_http

  process.sleep_forever()
}
