# TestServer

[![Github CI](https://github.com/danschultzer/test_server/workflows/CI/badge.svg)](https://github.com/danschultzer/test_server/actions?query=workflow%3ACI)
[![hex.pm](https://img.shields.io/hexpm/v/test_server.svg)](https://hex.pm/packages/test_server)

<!-- MDOC !-->

No fuzz ExUnit test server to mock third party services.

Features:

- HTTP/1
- HTTP/2
- WebSocket
- Built-in TLS with self-signed certificates
- Plug route matching

<!-- MDOC !-->

## Installation

Add `test_server` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:test_server, "~> 0.1.6", only: [:test]}
  ]
end
```

## Usage

```elixir
test "fetch_url/0" do
  # The test server will autostart the current test server, if not already running
  TestServer.add("/", via: :get)

  # The URL is derived from the current test server instance
  Application.put_env(:my_app, :fetch_url, TestServer.url())

  {:ok, "HTTP"} = MyModule.fetch_url()
end
```

The `TestServer.add/2` function can route a request to an anonymous function:

```elixir
TestServer.add("/", to: fn conn ->
  Plug.Conn.send_resp(conn, 200, "success")
end)
```

It can also route to a plug:

```elixir
TestServer.add("/", to: MyPlug)
```

The method to listen to can be defined with `:via`, by default it'll match any method:

```elixir
TestServer.add("/", via: :post)
```

A custom match function can be set with `:match` option:

```elixir
TestServer.add("/", match: fn
  %{params: %{"a" => 1}} = _conn -> true
  _conn -> false
end)
```

By default all routes are served as plain HTTP.

HTTPS can be enabled with the `:scheme` option when starting the test server. The certificate suite is automatically generated.

```elixir
{:ok, instance} = TestServer.start(scheme: :https)
cacerts = TestServer.x509_suite().cacerts
```

Custom SSL certificates can also be used by defining the cowboy options:

```elixir
TestServer.start(scheme: :https, cowboy_options: [keyfile: key, certfile: cert])
```

When a route is matched it'll be removed from active routes list. The route will be triggered in the order they were added:

```elixir
TestServer.add("/", via: :get, to: &Plug.Conn.send_resp(&1, 200, "first"))
TestServer.add("/", via: :get, to: &Plug.Conn.send_resp(&1, 200, "second"))

{:ok, "first"} = fetch_request()
{:ok, "second"} = fetch_request()
```

Plugs can be added to process requests before it matches any routes. If no plugs are defined `Plug.Conn.fetch_query_params/1` will run.

```elixir
TestServer.plug(fn conn ->
  Plug.Conn.fetch_query_params(conn)
end)

TestServer.plug(fn conn ->
  {:ok, body, _conn} = Plug.Conn.read_body(conn, [])

  %{conn | body_params: Jason.decode!(body)}
end)

TestServer.plug(MyPlug)
```

WebSocket endpoint can also be set up. By default the handler will echo what was received.

```elixir
test "WebSocketClient" do
  {:ok, socket} = TestServer.websocket_init("/ws")

  :ok = TestServer.websocket_handle(socket)
  :ok = TestServer.websocket_handle(socket, to: fn {:text, "ping"}, state -> {:reply, {:text, "pong"}, state} end)
  :ok = TestServer.websocket_handle(socket, match: fn {:text, message}, _state -> message == "hi")

  {:ok, client} = WebSocketClient.start_link(TestServer.url("/ws"))

  :ok = WebSocketClient.send(client, "hello")
  {:ok, "hello"} = WebSocketClient.receive(client)

  :ok = WebSocketClient.send(client, "ping")
  {:ok, "pong"} = WebSocketClient.receive(client)

  :ok = WebSocketClient.send("hi")
  {:ok, "hi"} = WebSocketClient.receive(client)

  :ok = TestServer.websocket_info(socket, fn state -> {:reply, {:text, "ping"}, state} end)
  {:ok, "ping"} = WebSocketClient.receive(client)
end
```

<!-- MDOC !-->

## LICENSE

(The MIT License)

Copyright (c) 2022 Dan Schultzer & the Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the 'Software'), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
