# HTTP / WebSocket

<!-- MDOC !-->

Mock HTTP/1, HTTP/2, and WebSocket endpoints with route expectations, plug pipelines, and TLS support.

## Usage

### HTTP

Add route request expectations with `TestServer.HTTP.handle/2`:

```elixir
test "fetch_url/1" do
  # The test server will autostart the current test server, if not already running
  TestServer.HTTP.handle("/", via: :get)

  assert MyModule.fetch_url(TestServer.HTTP.url()) == {:ok, "HTTP"}
end
```

`TestServer.HTTP.handle/2` can route a request to an anonymous function or plug with `:to` option.

```elixir
TestServer.HTTP.handle("/", to: fn conn ->
  Plug.Conn.send_resp(conn, 200, "OK")
end)

TestServer.HTTP.handle("/", to: MyPlug)
```

The method listened to can be defined with `:via` option. By default any method is matched.

```elixir
TestServer.HTTP.handle("/", via: :post)
```

A custom match function can be set with `:match` option:

```elixir
TestServer.HTTP.handle("/", match: fn
  %{params: %{"a" => "1"}} = _conn -> true
  _conn -> false
end)
```

When a route is matched it'll be removed from active routes list. The route will be triggered in the order they were added:

```elixir
TestServer.HTTP.handle("/", via: :get, to: &Plug.Conn.send_resp(&1, 200, "first"))
TestServer.HTTP.handle("/", via: :get, to: &Plug.Conn.send_resp(&1, 200, "second"))

assert fetch_request() == {:ok, "first"}
assert fetch_request() == {:ok, "second"}
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

By default the test server is set up to serve plain HTTP. HTTPS can be enabled with the `:scheme` option when calling `TestServer.HTTP.start/1`. A self-signed certificate suite is automatically generated:

```elixir
TestServer.HTTP.start!(scheme: :https)

req_options = [
  connect_options: [
    transport_opts: [cacerts: TestServer.HTTP.x509_suite().cacerts],
    protocols: [:http2]
  ]
]

assert {:ok, %Req.Response{status: 200, body: "HTTP/2"}} =
        Req.get(TestServer.HTTP.url(), req_options)
```

Custom TLS certificates can be used by setting the `:tls` option:

```elixir
TestServer.HTTP.start!(scheme: :https, tls: [keyfile: key, certfile: cert])
```

### WebSocket

WebSocket endpoint can be set up by calling `TestServer.HTTP.websocket/2`. By default, `TestServer.HTTP.websocket_handle/2` will echo the message received. Messages can be sent from the test server with `TestServer.HTTP.websocket_send/2`.

```elixir
test "WebSocketClient" do
  websocket = TestServer.HTTP.websocket("/ws")

  TestServer.HTTP.websocket_handle(websocket)
  TestServer.HTTP.websocket_handle(websocket, match: fn {:text, message}, _state -> message == "hi" end)
  TestServer.HTTP.websocket_handle(websocket, to: fn {:text, "ping"}, state -> {:reply, {:text, "pong"}, state} end)

  assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

  assert WebSocketClient.send(client, "hello") == :ok
  assert WebSocketClient.receive(client) == {:ok, "hello"}

  assert WebSocketClient.send(client, "ping") == :ok
  assert WebSocketClient.receive(client) == {:ok, "pong"}

  assert WebSocketClient.send(client, "hi") == :ok
  assert WebSocketClient.receive(client) == {:ok, "hi"}

  TestServer.HTTP.websocket_send(websocket, to: fn state -> {:reply, {:text, "ping"}, state} end)
  
  assert WebSocketClient.receive(client) == {:ok, "ping"}
end
```

*Note: WebSocket is not supported by the `:httpd` adapter.*

### HTTP Server Adapter

TestServer supports `Bandit`, `Plug.Cowboy`, and `:httpd` out of the box. The HTTP adapter will be selected in this order depending which is available in the dependencies. You can also explicitly set the http server in the configuration when calling `TestServer.HTTP.start/1`:

```elixir
TestServer.HTTP.start!(http_server: {TestServer.HTTP.Server.Bandit, []})
```

You can create your own plug based HTTP Server Adapter by using the `TestServer.HTTP.Server` behaviour.

### IPv6

Use the `:ipfamily` option to test with IPv6 when starting the test server with `TestServer.HTTP.start/1`:

```elixir
TestServer.HTTP.start!(ipfamily: :inet6)

TestServer.HTTP.handle("/",
  to: fn conn ->
    assert conn.remote_ip == {0, 0, 0, 0, 0, 65_535, 32_512, 1}

    Plug.Conn.resp(conn, 200, "OK")
  end
)
```

<!-- MDOC !-->
