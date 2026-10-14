# TCP

<!-- MDOC !-->

Mock TCP stream endpoints.

## Usage

Add data expectations with `TestServer.SSH.handle/2`:

```elixir
test "send/2" do
  # The test server will autostart the current test server, if not already
  # running, and a connection expectation will be set up if not already set.
  TestServer.TCP.handle()

  assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
  assert TCPClient.send(socket, "echo") == :ok
  assert TCPClient.receive_data(socket) == {:ok, "echo"}
end
```

`TestServer.TCP.handle/2` can route data to an anonymous function:

```elixir
TestServer.TCP.handle(to: fn _data, state -> {:reply, "pong", state} end)
```

A custom match function can be set with `:match` option:

```elixir
TestServer.TCP.handle(match: fn data, _state -> data == "ping" end)
```

Handlers are processed in the order they were added:

```elixir
TestServer.TCP.handle(to: fn _data, state -> {:reply, "first", state} end)
TestServer.TCP.handle(to: fn _data, state -> {:reply, "second", state} end)

assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
assert TCPClient.send(socket, "ping") == :ok
assert TCPClient.receive_data(socket) == {:ok, "first"}
assert TCPClient.send(socket, "ping") == :ok
assert TCPClient.receive_data(socket) == {:ok, "second"}
```

Use `TestServer.TCP.send/2` to send data from the server:

```elixir
connection = TestServer.TCP.connection()

assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

TestServer.TCP.send(connection, to: fn state -> {:reply, "ping", state} end)

assert TCPClient.receive_data(socket) == {:ok, "ping"}
```

Use `TestServer.TCP.connection/1` to expect multiple client connections or use with `TestServer.TCP.send/2`. They are assigned to accepted sockets in the order they are added:

```elixir
connection_1 = TestServer.TCP.connection()
connection_2 = TestServer.TCP.connection()

TestServer.TCP.handle(connection_1, to: fn _data, state -> {:reply, "connection 1", state} end)
TestServer.TCP.handle(connection_2, to: fn _data, state -> {:reply, "connection 2", state} end)

assert {:ok, socket_1} = TCPClient.connect(TestServer.TCP.address())
assert {:ok, socket_2} = TCPClient.connect(TestServer.TCP.address())
assert TCPClient.send(socket_1, "ping") == :ok
assert TCPClient.send(socket_2, "ping") == :ok
assert TCPClient.receive_data(socket_1) == {:ok, "connection 1"}
assert TCPClient.receive_data(socket_2) == {:ok, "connection 2"}
```

### IPv6

Use the `:ipfamily` option to test with IPv6:

```elixir
TestServer.TCP.start!(ipfamily: :inet6)

assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address(), [:inet6])
assert {{0, 0, 0, 0, 0, 0, 0, 1}, _port} = :inet.peername(socket)
```

### Example: SMTP

A practical use case for TCP test server would be to test an SMTP client, in this case `:gen_smtp`:

```elixir
test ":gen_smtp.send_blocking/2", %{test_pid: test_pid} do
  message =
    """
    From: from@example.com
    To: to@example.com
    Subject: Hello
    Content-Type: text/plain; charset=utf-8

    Hello from :gen_smtp!
    """

  TestServer.TCP.start!(listen: [packet: :line])

  connection = TestServer.TCP.connection()

  # EHLO handshake
  TestServer.TCP.handle(connection,
    to: fn data, state ->
      assert "EHLO " <> _ = data

      {:reply, "250 localhost\r\n", state}
    end
  )

  # MAIL FROM command
  TestServer.TCP.handle(connection,
    to: fn data, state ->
      assert data == "MAIL FROM:<from@example.com>\r\n"

      {:reply, "250 OK\r\n", state}
    end
  )

  # RCPT TO command
  TestServer.TCP.handle(connection,
    to: fn data, state ->
      assert data == "RCPT TO:<to@example.com>\r\n"

      {:reply, "250 OK\r\n", state}
    end
  )

  # DATA command
  TestServer.TCP.handle(connection,
    to: fn data, state ->
      assert data == "DATA\r\n"

      {:reply, "354 End data with <CR><LF>.<CR><LF>\r\n", Map.put(state, :email, "")}
    end
  )

  # Email content line by line
  Enum.each(0..7, fn _ ->
    TestServer.TCP.handle(connection,
      to: fn
        "." <> _, state ->
          assert state.email == message <> "\r\n"

          {:reply, "250 OK\r\n", state}

        data, state ->
          {:ok, %{state | email: state.email <> data}}
      end
    )
  end)

  # QUIT command
  TestServer.TCP.handle(connection,
    to: fn data, state ->
      assert data =~ "QUIT"

      send(test_pid, :smtp_quit)

      {:reply, "221 Bye\r\n", state}
    end
  )

  {host, port} = TestServer.TCP.address()

  # Send greeting as soon as the socket is established
  Task.start(fn ->
    TestServer.TCP.send(connection,
      to: fn state -> {:reply, "220 localhost ESMTP\r\n", state} end
    )
  end)

  options = [
    relay: String.to_charlist(host),
    port: port,
    tls: :never,
    auth: :never,
    no_mx_lookups: true
  ]

  assert :gen_smtp_client.send_blocking(
            {~c"from@example.com", [~c"to@example.com"], message},
            options
          ) == "OK\r\n"

  # :gen_smtp_client doesn't wait for the QUIT response so we want to ensure we received
  # the QUIT command before ending the test
  assert_receive :smtp_quit
end
```

<!-- MDOC !-->
