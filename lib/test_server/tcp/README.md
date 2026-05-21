# TCP

<!-- MDOC !-->

Mock TCP stream endpoints with FIFO data handlers.

## Usage

### Data handlers

Add FIFO data handlers with `TestServer.TCP.handle/1`:

```elixir
test "TCP client" do
  :ok =
    TestServer.TCP.handle(
      match: fn data, _state -> data == "PING\n" end,
      to: fn _data, state -> {:reply, "PONG\n", state} end
    )

  :ok = TestServer.TCP.handle()

  {:ok, socket} =
    :gen_tcp.connect(~c"localhost", elem(TestServer.TCP.address(), 1), [
      :binary,
      active: false,
      packet: :line
    ])

  :ok = :gen_tcp.send(socket, "PING\n")
  assert {:ok, "PONG\n"} = :gen_tcp.recv(socket, 0)

  :ok = :gen_tcp.send(socket, "echo\n")
  assert {:ok, "echo\n"} = :gen_tcp.recv(socket, 0)
end
```

The server autostarts when `handle/1` is called. Start it explicitly when you
need custom socket options:

```elixir
TestServer.TCP.start(listen_options: [:binary, packet: :line])
```

TCP is a stream protocol, so data delivered to handlers follows the configured
`:gen_tcp` packet options. Use `:listen_options` to set framing such as
`packet: :line`, `packet: 4`, or raw stream mode.

### Targeting a specific connection

Register a connection with `TestServer.TCP.connect/0` to get a connection ref
you can scope handlers and sends to. Connections are bound to incoming
sockets FIFO: the first registered ref takes the first accepted socket, the
second ref the second socket, and so on. Sockets that arrive while no ref is
waiting are accepted as anonymous connections that only match handlers
registered without a ref.

```elixir
{:ok, conn1} = TestServer.TCP.connect()
{:ok, conn2} = TestServer.TCP.connect()

:ok = TestServer.TCP.handle(conn1, to: fn _data, state -> {:reply, "one", state} end)
:ok = TestServer.TCP.handle(conn2, to: fn _data, state -> {:reply, "two", state} end)

{:ok, socket1} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
{:ok, socket2} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])

:ok = :gen_tcp.send(socket1, "ping")
assert {:ok, "one"} = :gen_tcp.recv(socket1, 0)
:ok = :gen_tcp.send(socket2, "ping")
assert {:ok, "two"} = :gen_tcp.recv(socket2, 0)
```

### Matching and replies

By default, `TestServer.TCP.handle/1` echoes received data:

```elixir
:ok = TestServer.TCP.handle()
```

Use `:match` to select data and `:to` to customize the response:

```elixir
TestServer.TCP.handle(
  match: fn data, _state -> data == "HELLO" end,
  to: fn _data, state -> {:reply, "READY", state} end
)
```

The two-arity `:to` callback can return:

```elixir
{:reply, data, state}
{:ok, state}
```

The `:match` and `:to` callbacks run inside the test server instance process,
so they must not call back into the `TestServer.TCP` API for the same
instance.

### Sending data

Push data from the test server to a specific connection with
`TestServer.TCP.send/2`:

```elixir
{:ok, conn} = TestServer.TCP.connect()

{:ok, socket} =
  :gen_tcp.connect(~c"localhost", elem(TestServer.TCP.address(), 1), [
    :binary,
    active: false
  ])

:ok =
  TestServer.TCP.send(conn,
    to: fn state -> {:reply, "hello", state} end
  )

assert {:ok, "hello"} = :gen_tcp.recv(socket, 0)
```

### Example: a minimal SMTP exchange

The pieces above compose into a realistic protocol mock. SMTP servers greet
first with a `220` banner, then answer each client command in turn, so this
combines a server-initiated `send/2` with a FIFO sequence of scoped handlers:

```elixir
test "SMTP client" do
  {:ok, conn} = TestServer.TCP.connect()

  # One handler per client command, matched FIFO on the same connection.
  :ok =
    TestServer.TCP.handle(conn,
      match: fn data, _state -> String.starts_with?(data, "EHLO") end,
      to: fn _data, state -> {:reply, "250 test.server\r\n", state} end
    )

  :ok =
    TestServer.TCP.handle(conn,
      match: fn data, _state -> String.starts_with?(data, "MAIL FROM") end,
      to: fn _data, state -> {:reply, "250 OK\r\n", state} end
    )

  :ok =
    TestServer.TCP.handle(conn,
      match: fn data, _state -> String.starts_with?(data, "RCPT TO") end,
      to: fn _data, state -> {:reply, "250 OK\r\n", state} end
    )

  :ok =
    TestServer.TCP.handle(conn,
      match: fn data, _state -> String.starts_with?(data, "DATA") end,
      to: fn _data, state -> {:reply, "354 End data with <CR><LF>.<CR><LF>\r\n", state} end
    )

  # The message body and its `.` terminator arrive as one chunk under raw
  # framing, so a single handler matches the trailing `\r\n.\r\n`.
  :ok =
    TestServer.TCP.handle(conn,
      match: fn data, _state -> String.ends_with?(data, "\r\n.\r\n") end,
      to: fn _data, state -> {:reply, "250 OK: queued\r\n", state} end
    )

  :ok =
    TestServer.TCP.handle(conn,
      match: fn data, _state -> String.starts_with?(data, "QUIT") end,
      to: fn _data, state -> {:reply, "221 Bye\r\n", state} end
    )

  {:ok, socket} =
    :gen_tcp.connect(~c"localhost", elem(TestServer.TCP.address(), 1), [
      :binary,
      active: false
    ])

  # SMTP servers greet first.
  :ok =
    TestServer.TCP.send(conn,
      to: fn state -> {:reply, "220 test.server ESMTP\r\n", state} end
    )

  assert {:ok, "220 test.server ESMTP\r\n"} = :gen_tcp.recv(socket, 0)

  :ok = :gen_tcp.send(socket, "EHLO client\r\n")
  assert {:ok, "250 test.server\r\n"} = :gen_tcp.recv(socket, 0)

  :ok = :gen_tcp.send(socket, "MAIL FROM:<me@example.com>\r\n")
  assert {:ok, "250 OK\r\n"} = :gen_tcp.recv(socket, 0)

  :ok = :gen_tcp.send(socket, "RCPT TO:<you@example.com>\r\n")
  assert {:ok, "250 OK\r\n"} = :gen_tcp.recv(socket, 0)

  :ok = :gen_tcp.send(socket, "DATA\r\n")
  assert {:ok, "354" <> _} = :gen_tcp.recv(socket, 0)

  :ok = :gen_tcp.send(socket, "Subject: Hi\r\n\r\nHello there!\r\n.\r\n")
  assert {:ok, "250 OK: queued\r\n"} = :gen_tcp.recv(socket, 0)

  :ok = :gen_tcp.send(socket, "QUIT\r\n")
  assert {:ok, "221 Bye\r\n"} = :gen_tcp.recv(socket, 0)
end
```

### IPv6

Use the `:ipfamily` option to test with IPv6:

```elixir
{:ok, _instance} = TestServer.TCP.start(ipfamily: :inet6)
:ok = TestServer.TCP.handle()

assert {"localhost", port} = TestServer.TCP.address()

{:ok, socket} =
  :gen_tcp.connect(~c"localhost", port, [:binary, active: false, :inet6])
```

<!-- MDOC !-->
