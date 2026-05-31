# SSH

<!-- MDOC !-->

Mock SSH endpoint with channel and message expectations, and password/public key authentication.

## Usage

### Channels

Session channels can be set up by calling `TestServer.SSH.channel/2`. By default `TestServer.SSH.handle/2` will echo the message sent. The handlers that match the message will be called in the order they were specified.

```elixir
test "SSHClient" do
  {:ok, channel} = TestServer.SSH.channel()

  # Only matches `hi` data message
  :ok =
    TestServer.SSH.handle(
      channel,
      match: fn {:data, _channel_id, _want_reply, data}, _state ->
        data == "hi"
      end
    )

  # Reply with `pong` message
  :ok =
    TestServer.SSH.handle(
      channel,
      to: fn {:data, _channel_id, _want_reply, _data}, state ->
        {:reply, "pong", state}
      end
    )

  # Default data echo
  :ok = TestServer.SSH.handle(channel)

  assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
  assert {:ok, channel_id} = SSHClient.session_channel(conn)
  assert :ok = SSHClient.send(conn, channel_id, "ping")
  assert {:ok, "pong"} = SSHClient.receive_data(conn, channel_id)
  assert :ok = SSHClient.send(conn, channel_id, "hi")
  assert {:ok, "hi"} = SSHClient.receive_data(conn, channel_id)
  assert :ok = SSHClient.send(conn, channel_id, "hello")
  assert {:ok, "hello"} = SSHClient.receive_data(conn, channel_id)
  assert :ok = SSHClient.close(conn)
end
```

By default, only `:exec` and `:data` messages are dispatched to handlers. Use the `:listen` option on `TestServer.SSH.channel/2` to control which message types are dispatched:

```elixir
{:ok, channel_1} = TestServer.SSH.channel(listen: :all)
{:ok, channel_2} = TestServer.SSH.channel(listen: [:data, :env, :pty])
```

### Host keys

Host keys can be configured in `TestServer.SSH.start/1`. By default host keys are auto generated to cover most algorithms and can be fetched with `TestServer.SSH.host_keys/1`

```elixir
host_key = :public_key.generate_key({:rsa, 2048, 65_537})
{:ok, instance} = TestServer.SSH.start(host_keys: [host_key])

[%{fingerprint: fingerprint}] = TestServer.SSH.host_keys(instance)
```

### Authentication

By default the test server accepts unauthenticated requests. Pass in `:user_passwords` and/or `:auth_keys` options to `TestServer.SSH.start/1` to require authentication:

```elixir
{:RSAPrivateKey, _, mod, exp, _, _, _, _, _, _, _} =
  :public_key.generate_key({:rsa, 2048, 65_537})

TestServer.SSH.start(
  user_passwords: [{"user1", "pass"}],
  auth_keys: [{"user2", {:RSAPublicKey, mod, exp}}]
)
```

### IPv6

Use the `:ipfamily` option to test with IPv6 when starting the test server with `TestServer.SSH.start/1`:

```elixir
{:ok, _instance} = TestServer.SSH.start(ipfamily: :inet6)

assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address(), inet6: true)
assert {{0, 0, 0, 0, 0, 0, 0, 1}, _port} = SSHClient.sockname(conn)
```

<!-- MDOC !-->
