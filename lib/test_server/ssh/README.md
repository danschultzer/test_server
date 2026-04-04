# SSH

<!-- MDOC !-->

Mock SSH server for testing. Supports command expectations, password and public key authentication, exec and shell channels.

## Usage

### Basic Commands

Add command expectations with `TestServer.SSH.command/0,1,2`:

```elixir
test "deploy script runs command over SSH" do
  # Autostart and expect any command, echo input back
  TestServer.SSH.command()

  {host, port} = TestServer.SSH.address()
  Application.put_env(:my_app, :ssh, host: host, port: port)

  {:ok, "deploy"} = MyModule.run_command("deploy")
end
```

### Progressive Disclosure

The `command` function accepts 0, 1, or 2 arguments for progressive control:

```elixir
# Match anything, echo input back
TestServer.SSH.command()

# Match exact string, echo input back
TestServer.SSH.command("deploy")

# Match regex, echo input back
TestServer.SSH.command(~r/git-upload-pack/)

# Match function, echo input back
TestServer.SSH.command(fn cmd -> String.starts_with?(cmd, "git") end)

# Custom response handler
TestServer.SSH.command("deploy", to: fn _input ->
  {:reply, "deployed successfully"}
end)
```

### Response Format

Handler functions return one of:

```elixir
# Send data back to client
{:reply, data}

# Send data with exit code and/or stderr (exec only)
{:reply, data, exit_status: 0, stderr: "warning"}

# No reply
:ok
```

### Type-Specific Matching

Handlers receive a tagged tuple `{type, input}` where `type` is `:exec` or `:data`.
Use pattern matching to filter by protocol type:

```elixir
# Only match exec requests
TestServer.SSH.command(match: fn {:exec, _input}, _state -> true end)

# Only match shell input
TestServer.SSH.command(match: fn {:data, _input}, _state -> true end)
```

### Custom Match Functions

Use the `:match` option for advanced matching:

```elixir
TestServer.SSH.command(match: fn {_type, input}, _state ->
  String.contains?(input, "secret")
end, to: fn _msg, state ->
  {:reply, "classified", state}
end)
```

### Authentication

Configure credentials when starting the server:

```elixir
# Password authentication
TestServer.SSH.start(credentials: [{"user", "pass"}])

# Public key authentication
TestServer.SSH.start(credentials: [{"user", {:public_key, pem_data}}])

# No credentials — all connections accepted (default)
TestServer.SSH.start()
```

### Handler Matching

Handlers are matched FIFO (first in, first out). When a command arrives, the first non-suspended handler that matches is invoked and then suspended. Any commands not matched by a handler, or any handlers not consumed by a command, will raise an error in the test case.

```elixir
TestServer.SSH.command("first")
TestServer.SSH.command("second")

# Client sends "first" → matched by first handler
# Client sends "second" → matched by second handler
```

### Multiple Instances

```elixir
{:ok, server_1} = TestServer.SSH.start()
{:ok, server_2} = TestServer.SSH.start()

TestServer.SSH.command(server_1, "cmd1")
TestServer.SSH.command(server_2, "cmd2")

{host, port_1} = TestServer.SSH.address(server_1)
{host, port_2} = TestServer.SSH.address(server_2)
```

<!-- MDOC !-->
