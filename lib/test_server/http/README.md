# HTTP / WebSocket

<!-- MDOC !-->

Mock HTTP/1, HTTP/2, and WebSocket endpoints with plug pipelines and TLS support.

## Usage

Add request expectations with `TestServer.HTTP.handle/2`:

```elixir
test "fetch_url/1" do
  # The test server will autostart the current test server if not already running
  TestServer.HTTP.handle("/path", method: :get)

  assert HTTPClient.fetch_url(TestServer.HTTP.url("/path")) == {:ok, "HTTP/1.1"}
end
```

`TestServer.HTTP.handle/2` can route a request to an anonymous function or plug using the `:to` option.

```elixir
TestServer.HTTP.handle(to: fn conn ->
  Plug.Conn.send_resp(conn, 200, "OK")
end)

TestServer.HTTP.handle(to: MyPlug)
```

The path can be passed as the first argument or defined with the `:path` option. By default any path is matched.

```elixir
TestServer.HTTP.handle()
TestServer.HTTP.handle("/path")
TestServer.HTTP.handle(path: "/path")
```

The HTTP method can be matched with the `:method` option. By default any method is matched.

```elixir
TestServer.HTTP.handle(method: :post)
```

A custom match function can be set with the `:match` option. The `:path` and `:method` options, if set, are matched first:

```elixir
TestServer.HTTP.handle(match: fn
  %{params: %{"a" => "1"}} = _conn -> true
  _conn -> false
end)
```

When a handler is matched it is removed from the list of active handlers. Handlers are triggered in the order they were added:

```elixir
TestServer.HTTP.handle(to: &Plug.Conn.send_resp(&1, 200, "first"))
TestServer.HTTP.handle(to: &Plug.Conn.send_resp(&1, 200, "second"))

assert HTTPClient.fetch_url(TestServer.HTTP.url()) == {:ok, "first"}
assert HTTPClient.fetch_url(TestServer.HTTP.url()) == {:ok, "second"}
```

Plugs can be added to the pipeline with `TestServer.HTTP.plug/1`. All plugs will run before any handlers are matched. `Plug.Conn.fetch_query_params/1` is used if no plugs are set.

```elixir
TestServer.HTTP.plug(fn conn ->
  Plug.Conn.fetch_query_params(conn)
end)

TestServer.HTTP.plug(fn conn ->
  {:ok, body, conn} = Plug.Conn.read_body(conn, [])

  %{conn | body_params: Jason.decode!(body)}
end)

TestServer.HTTP.plug(MyPlug)
```

## HTTPS

By default the test server serves plain HTTP. HTTPS can be enabled with the `:scheme` option when calling `TestServer.HTTP.start/1`. A self-signed certificate suite is automatically generated:

```elixir
TestServer.HTTP.start!(scheme: :https)
TestServer.HTTP.handle()

req_options = [
  connect_options: [
    transport_opts: [cacerts: TestServer.HTTP.cacerts()],
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

## WebSocket

A WebSocket endpoint can be set up by calling `TestServer.HTTP.websocket/1`. By default any path is matched, and `TestServer.HTTP.websocket_handle/2` echoes the received message. Messages can be sent from the test server with `TestServer.HTTP.websocket_send/2`.

```elixir
test "WebSocketClient" do
  websocket = TestServer.HTTP.websocket("/ws")

  TestServer.HTTP.websocket_handle(websocket,
    to: fn {:text, "ping"}, state -> {:reply, {:text, "pong"}, state} end
  )

  assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

  assert WebSocketClient.send(client, "ping") == :ok
  assert WebSocketClient.receive(client) == {:ok, "pong"}

  TestServer.HTTP.websocket_send(websocket,
    to: fn state -> {:reply, {:text, "hello"}, state} end
  )

  assert WebSocketClient.receive(client) == {:ok, "hello"}
end
```

*Note: WebSocket is not supported by the `m::httpd` adapter.*

## HTTP Server Adapter

TestServer supports `Bandit`, `Plug.Cowboy`, and `m::httpd` out of the box. The HTTP adapter is selected in this order based on which dependencies are available. You can also explicitly set the HTTP server when calling `TestServer.HTTP.start/1`:

```elixir
TestServer.HTTP.start!(http_server: {TestServer.HTTP.Server.Bandit, []})
```

You can create your own Plug-based HTTP server adapter using the `TestServer.HTTP.Server` behaviour.

## IPv6

Use the `:ipfamily` option to test with IPv6 when starting the test server with `TestServer.HTTP.start/1`:

```elixir
TestServer.HTTP.start!(ipfamily: :inet6)

TestServer.HTTP.handle(
  to: fn conn ->
    assert conn.remote_ip == {0, 0, 0, 0, 0, 65_535, 32_512, 1}

    Plug.Conn.resp(conn, 200, "OK")
  end
)

assert HTTPClient.fetch_url(TestServer.HTTP.url()) == {:ok, "OK"}
```

<!-- MDOC !-->
