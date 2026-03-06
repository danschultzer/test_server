# TestServer

[![Github CI](https://github.com/danschultzer/test_server/workflows/CI/badge.svg)](https://github.com/danschultzer/test_server/actions?query=workflow%3ACI)
[![hex.pm](https://img.shields.io/hexpm/v/test_server.svg)](https://hex.pm/packages/test_server)

<!-- MDOC !-->

No fuzz ExUnit test server to mock third party services.

Features:

- HTTP/1
- HTTP/2
- WebSocket
- SSH
- Built-in TLS with self-signed certificates
- Plug route matching

## Usage

### HTTP

Add route request expectations with `TestServer.HTTP.add/2`:

```elixir
test "fetch_url/0" do
  # The test server will autostart the current test server, if not already running
  TestServer.HTTP.add("/", via: :get)

  # The URL is derived from the current test server instance
  Application.put_env(:my_app, :fetch_url, TestServer.HTTP.url())

  {:ok, "HTTP"} = MyModule.fetch_url()
end
```

`TestServer.HTTP.add/2` can route a request to an anonymous function or plug with `:to` option.

```elixir
TestServer.HTTP.add("/", to: fn conn ->
  Plug.Conn.send_resp(conn, 200, "OK")
end)

TestServer.HTTP.add("/", to: MyPlug)
```

The method listened to can be defined with `:via` option. By default any method is matched.

```elixir
TestServer.HTTP.add("/", via: :post)
```

A custom match function can be set with `:match` option:

```elixir
TestServer.HTTP.add("/", match: fn
  %{params: %{"a" => "1"}} = _conn -> true
  _conn -> false
end)
```

When a route is matched it'll be removed from active routes list. The route will be triggered in the order they were added:

```elixir
TestServer.HTTP.add("/", via: :get, to: &Plug.Conn.send_resp(&1, 200, "first"))
TestServer.HTTP.add("/", via: :get, to: &Plug.Conn.send_resp(&1, 200, "second"))

{:ok, "first"} = fetch_request()
{:ok, "second"} = fetch_request()
```

Plugs can be added to the pipeline with `TestServer.HTTP.plug/1`. All plugs will run before any routes are matched. `Plug.Conn.fetch_query_params/1` is used if no plugs are set.

```elixir
TestServer.HTTP.plug(fn conn ->
  Plug.Conn.fetch_query_params(conn)
end)

TestServer.HTTP.plug(fn conn ->
  {:ok, body, _conn} = Plug.Conn.read_body(conn, [])

  %{conn | body_params: Jason.decode!(body)}
end)

TestServer.HTTP.plug(MyPlug)
```

### HTTPS

By default the test server is set up to serve plain HTTP. HTTPS can be enabled with the `:scheme` option when calling `TestServer.HTTP.start/1`.

Custom SSL certificates can also be used by defining the `:tls` option:

```elixir
TestServer.HTTP.start(scheme: :https, tls: [keyfile: key, certfile: cert])
```

A self-signed certificate suite is automatically generated if you don't set the `:tls` options:

```elixir
TestServer.HTTP.start(scheme: :https)

req_opts = [
  connect_options: [
    transport_opts: [cacerts: TestServer.HTTP.x509_suite().cacerts],
    protocols: [:http2]
  ]
]

assert {:ok, %Req.Response{status: 200, body: "HTTP/2"}} =
        Req.get(TestServer.HTTP.url(), req_opts)
```

### WebSocket

WebSocket endpoint can be set up by calling `TestServer.HTTP.websocket_init/2`. By default, `TestServer.HTTP.websocket_handle/2` will echo the message received. Messages can be send from the test server with `TestServer.HTTP.websocket_info/2`.

```elixir
test "WebSocketClient" do
  {:ok, socket} = TestServer.HTTP.websocket_init("/ws")

  :ok = TestServer.HTTP.websocket_handle(socket)
  :ok = TestServer.HTTP.websocket_handle(socket, to: fn {:text, "ping"}, state -> {:reply, {:text, "pong"}, state} end)
  :ok = TestServer.HTTP.websocket_handle(socket, match: fn {:text, message}, _state -> message == "hi" end)

  {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

  :ok = WebSocketClient.send(client, "hello")
  {:ok, "hello"} = WebSocketClient.receive(client)

  :ok = WebSocketClient.send(client, "ping")
  {:ok, "pong"} = WebSocketClient.receive(client)

  :ok = WebSocketClient.send("hi")
  {:ok, "hi"} = WebSocketClient.receive(client)

  :ok = TestServer.HTTP.websocket_info(socket, fn state -> {:reply, {:text, "ping"}, state} end)
  {:ok, "ping"} = WebSocketClient.receive(client)
end
```

*Note: WebSocket is not supported by the `:httpd` adapter.*

### SSH

SSH exec and shell handlers can be registered with `TestServer.SSH.exec/1` and `TestServer.SSH.shell/1`. The server autostarts on first use and is torn down when the test exits.

```elixir
test "run remote command" do
  TestServer.SSH.exec(to: fn _cmd, state ->
    {:reply, {0, "file1\nfile2\n", ""}, state}
  end)

  {host, port} = TestServer.SSH.address()
  {:ok, conn} = :ssh.connect(String.to_charlist(host), port,
    user: ~c"test",
    silently_accept_hosts: true,
    user_interaction: false
  )

  {:ok, ch} = :ssh_connection.session_channel(conn, :infinity)
  :success = :ssh_connection.exec(conn, ch, ~c"ls", :infinity)
  # collect stdout, exit_status, closed messages...
end
```

Password and public key credentials can be set with the `:credentials` option:

```elixir
# Password auth
TestServer.SSH.start(credentials: [{"alice", "secret"}])

# Public key auth
TestServer.SSH.start(credentials: [{"bob", :public_key, pem_binary}])

# No auth (default — accepts any connection)
TestServer.SSH.start()
```

Handlers are matched FIFO and can be filtered with `:match`:

```elixir
TestServer.SSH.exec(
  match: fn cmd, _state -> cmd == "ls" end,
  to: fn _cmd, state -> {:reply, {0, "file1\n", ""}, state} end
)
```

### HTTP Server Adapter

TestServer supports `Bandit`, `Plug.Cowboy`, and `:httpd` out of the box. The HTTP adapter will be selected in this order depending which is available in the dependencies. You can also explicitly set the http server in the configuration when calling `TestServer.HTTP.start/1`:

```elixir
TestServer.HTTP.start(http_server: {TestServer.HTTPServer.Bandit, []})
```

You can create your own plug based HTTP Server Adapter by using the `TestServer.HTTPServer` behaviour.

### IPv6

Use the `:ipfamily` option to test with IPv6 when starting the test server with `TestServer.HTTP.start/1`:

```elixir
TestServer.HTTP.start(ipfamily: :inet6)

assert :ok =
          TestServer.HTTP.add("/",
            to: fn conn ->
              assert conn.remote_ip == {0, 0, 0, 0, 0, 65_535, 32_512, 1}

              Plug.Conn.resp(conn, 200, "OK")
            end
          )
```

<!-- MDOC !-->

## Installation

Add `test_server` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:test_server, "~> 0.1", only: [:test]}
  ]
end
```

## LICENSE

(The MIT License)

Copyright (c) 2022 Dan Schultzer & the Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the 'Software'), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
