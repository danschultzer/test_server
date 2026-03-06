# SSH

<!-- MDOC !-->

Mock SSH servers with exec and shell handler expectations, password and public key authentication.

### Exec

Add exec handler expectations with `TestServer.SSH.exec/1`. By default the handler returns exit code 0 with empty stdout and stderr.

```elixir
test "runs a remote command" do
  # The test server will autostart if not already running
  TestServer.SSH.exec(to: fn _cmd, state -> {:reply, {0, "deployed v1.0\n", ""}, state} end)

  {host, port} = TestServer.SSH.address()
  assert {:ok, 0, "deployed v1.0\n", ""} = MyApp.SSH.run(host, port, "deploy")
end
```

The `:to` handler receives `{command, state}` and must return `{:reply, {exit_code, stdout, stderr}, state}`:

```elixir
TestServer.SSH.exec(to: fn _cmd, state -> {:reply, {1, "", "permission denied\n"}, state} end)
```

A `:match` function can be set to conditionally dispatch to a handler:

```elixir
TestServer.SSH.exec(match: fn cmd, _state -> cmd == "deploy" end, to: &deploy_handler/2)
TestServer.SSH.exec(match: fn cmd, _state -> cmd == "status" end, to: &status_handler/2)
```

When a handler is matched it is consumed. Handlers are dispatched in the order they were added (FIFO):

```elixir
TestServer.SSH.exec(to: fn _, state -> {:reply, {0, "deploy 1\n", ""}, state} end)
TestServer.SSH.exec(to: fn _, state -> {:reply, {0, "deploy 2\n", ""}, state} end)

assert {:ok, 0, "deploy 1\n", ""} = MyApp.SSH.run(host, port, "deploy")
assert {:ok, 0, "deploy 2\n", ""} = MyApp.SSH.run(host, port, "deploy")
```

### Shell

Add shell handler expectations with `TestServer.SSH.shell/1`. By default the handler echoes received data.

```elixir
test "interactive shell session" do
  TestServer.SSH.shell(to: fn data, state -> {:reply, "echo: " <> data, state} end)

  {host, port} = TestServer.SSH.address()
  {:ok, response} = MyApp.SSH.shell(host, port, "hello\n")
  assert response == "echo: hello\n"
end
```

### Authentication

#### Password

Pass a list of `{username, password}` tuples as `:credentials`:

```elixir
{:ok, instance} = TestServer.SSH.start(credentials: [{"deploy", "hunter2"}])
TestServer.SSH.exec(instance, to: fn _, state -> {:reply, {0, "ok\n", ""}, state} end)

{host, port} = TestServer.SSH.address(instance)
assert {:ok, 0, "ok\n", ""} = MyApp.SSH.run(host, port, "deploy", user: "deploy", password: "hunter2")
```

#### Public Key

Pass a `{username, :public_key, pem_binary}` tuple in `:credentials`:

```elixir
pem = File.read!("test/fixtures/id_rsa.pem")
{:ok, instance} = TestServer.SSH.start(credentials: [{"deploy", :public_key, pem}])
```

#### No Authentication

Omit the `:credentials` option entirely to accept any connection without authentication:

```elixir
{:ok, _instance} = TestServer.SSH.start()
# All clients are accepted regardless of credentials
```

<!-- MDOC !-->
