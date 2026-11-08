# SSH

<!-- MDOC !-->

Mock SSH endpoint with channel and message expectations, and password/public key authentication.

## Usage

Add message expectations with `TestServer.SSH.handle/2`:

```elixir
test "send/3" do
  # The test server will autostart the current test server, if not already
  # running, and a channel expectation will be set up if not already set.
  TestServer.SSH.handle()

  assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
  assert {:ok, channel_id} = SSHClient.session_channel(conn)
  assert SSHClient.send(conn, channel_id, "echo") == :ok
  assert SSHClient.receive_data(conn, channel_id) == {:ok, "echo"}
end
```

`TestServer.SSH.handle/2` can route a message to an anonymous function with `:to` option.

```elixir
TestServer.SSH.handle(
  to: fn {:data, _channel_id, _want_reply, _data}, state ->
    {:reply, "pong", state}
  end
)
```

A custom `:match` function can select a message.

```elixir
TestServer.SSH.handle(
  match: fn
    {:data, _channel_id, _want_reply, "ping"}, _state -> true
    _message, _state -> false
  end
)
```

When a message is matched the handle will be removed from active list. The handler will be triggered in the order they were added:

```elixir
TestServer.SSH.handle(fn _, state -> {:reply, "first", state} end)
TestServer.SSH.handle(fn _, state -> {:reply, "second", state} end)

assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
assert {:ok, channel_id} = SSHClient.session_channel(conn)
assert SSHClient.send(conn, channel_id, "hello") == :ok
assert SSHClient.receive_data(conn, channel_id) == {:ok, "first"}
assert SSHClient.send(conn, channel_id, "hello") == :ok
assert SSHClient.receive_data(conn, channel_id) == {:ok, "second"}
```

Use `TestServer.SSH.channel/2` to expect multiple session channels:

```elixir
channel_1 = TestServer.SSH.channel()
channel_2 = TestServer.SSH.channel()

TestServer.SSH.handle(channel_1, to: fn _data, state -> {:reply, "channel 1", state} end)
TestServer.SSH.handle(channel_2, to: fn _data, state -> {:reply, "channel 2", state} end)

assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
assert {:ok, channel_id_1} = SSHClient.session_channel(conn)
assert {:ok, channel_id_2} = SSHClient.session_channel(conn)
assert SSHClient.exec(conn, channel_id_2, "ping") == :ok
assert SSHClient.exec(conn, channel_id_1, "ping") == :ok
assert SSHClient.receive_data(conn, channel_id_1) == {:ok, "channel 2"}
assert SSHClient.receive_data(conn, channel_id_2) == {:ok, "channel 1"}
assert SSHClient.close(conn) == :ok
```

By default channel expectations sets up the channel to only dispatch `:exec` and `:data` message types. `:messages` can be set to control the message types:

```elixir
channel_1 = TestServer.SSH.channel(messages: :all)
channel_2 = TestServer.SSH.channel(messages: [:data, :env, :pty])
```

An `:exec` handler can keep the channel open to exchange more messages by setting `close: false` in the response:

```elixir
TestServer.SSH.handle(
  to: fn {:exec, _channel_id, _want_reply, _command}, state ->
    {:reply, {"ready", close: false}, state}
  end
)

TestServer.SSH.handle(
  to: fn {:data, _channel_id, _type, "ping"}, state ->
    {:reply, {"pong", close: true}, state}
  end
)
```

Subsystems can be added with the `:subsystems` option. The state in the channel is initialized with `%{subsystem: subsystem}`:

```elixir
TestServer.SSH.start!(subsystems: ["example"])
TestServer.SSH.handle(to: fn _frame, state -> {:reply, state.subsystem, state} end)

assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
assert {:ok, channel_id} = SSHClient.subsystem(conn, "example")
assert :ok = SSHClient.send(conn, channel_id, "ping")
assert SSHClient.receive_data(conn, channel_id) == {:ok, "example"}
```

### Host keys

Host keys can be configured in `TestServer.SSH.start/1`. By default host keys are auto generated to cover most algorithms and can be fetched with `TestServer.SSH.host_keys/1`

```elixir
host_key = :public_key.generate_key({:rsa, 2048, 65_537})
instance = TestServer.SSH.start!(host_keys: [host_key])
[%{fingerprint: fingerprint}] = TestServer.SSH.host_keys(instance)
```

### Authentication

By default the test server accepts unauthenticated requests. Pass in `:user_passwords` and/or `:auth_keys` options to `TestServer.SSH.start/1` to require authentication:

```elixir
{:RSAPrivateKey, _, mod, exp, _, _, _, _, _, _, _} =
  :public_key.generate_key({:rsa, 2048, 65_537})

TestServer.SSH.start!(
  user_passwords: [{"user1", "pass"}],
  auth_keys: [{"user2", {:RSAPublicKey, mod, exp}}]
)
```

### IPv6

Use the `:ipfamily` option to test with IPv6 when starting the test server with `TestServer.SSH.start/1`:

```elixir
TestServer.SSH.start!(ipfamily: :inet6)

assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address(), inet6: true)
assert {{0, 0, 0, 0, 0, 0, 0, 1}, _port} = SSHClient.sockname(conn)
```

### Example: SSHKit

The SSH test server can test an SSH client such as `SSHKit`:

```elixir
test "SSHKit.run/2" do
  TestServer.SSH.handle(
    to: fn {:exec, _channel_id, _want_reply, command}, state ->
      assert to_string(command) == "/usr/bin/env echo \"Hello World!\""

      {:reply, "Hello World!\n", state}
    end
  )

  {host, port} = TestServer.SSH.address()

  [{:ok, output, 0}] =
    {host, port: port, silently_accept_hosts: true, user_interaction: false}
    |> SSHKit.context()
    |> SSHKit.run("echo \"Hello World!\"")

  stdout =
    output
    |> Keyword.get_values(:stdout)
    |> Enum.join()

  assert "Hello World!\n" == stdout
end
```

<!-- MDOC !-->
