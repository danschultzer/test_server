# SSH

<!-- MDOC !-->

Mock SSH server for testing. Supports command expectations, password and public key authentication, exec and shell channels.

## Usage

### Basic Commands

Add command expectations with `TestServer.SSH.handle/0,1,2`:

```elixir
test "deploy script runs command over SSH" do
  # Autostart and expect any command, echo input back
  TestServer.SSH.handle()

  {host, port} = TestServer.SSH.address()
  Application.put_env(:my_app, :ssh, host: host, port: port)

  {:ok, "deploy"} = MyModule.run_command("deploy")
end
```

### Handler Callbacks

Handlers receive raw SSH message tuples. The shape depends on the message type:

```elixir
# Exec: command is a charlist
{:exec, channel_id, want_reply, command}

# Shell data: data is binary
{:data, channel_id, type, data}

# Environment variable (requires listen: [:env, ...])
{:env, channel_id, want_reply, var, val}

# PTY allocation (requires listen: [:pty, ...])
{:pty, channel_id, want_reply, pty_info}

# Shell request (requires listen: [:shell, ...])
{:shell, channel_id, want_reply}

# End of file (requires listen: [:eof, ...])
{:eof, channel_id}
```

### Response Format

Handler functions return one of:

```elixir
# Send data back to client
{:reply, data, state}

# Send data with exit code and/or stderr (exec only)
{:reply, {data, exit_status: code, stderr: message}, state}

# Consume handler without sending a reply or closing the channel
{:ignore, state}

# No reply
{:ok, state}
```

### Progressive Disclosure

```elixir
# Match anything, echo input back
TestServer.SSH.handle()

# Custom response handler
TestServer.SSH.handle(to: fn {:exec, _ch, _wr, command}, state ->
  {:reply, "got: #{to_string(command)}", state}
end)
```

### Custom Match Functions

Use the `:match` option for advanced matching:

```elixir
TestServer.SSH.handle(
  match: fn {:exec, _ch, _wr, cmd}, _state ->
    to_string(cmd) == "deploy"
  end,
  to: fn _msg, state ->
    {:reply, "deployed!", state}
  end
)
```

### Listen Option

By default, only `:exec` and `:data` messages are dispatched to handlers. Other
messages (`:env`, `:pty`, `:shell`, `:eof`) are auto-replied by the channel.

Use the `:listen` option to control which message types are dispatched:

```elixir
# Default — only exec and data dispatched
TestServer.SSH.start()

# Listen to everything
TestServer.SSH.start(listen: :all)

# Listen to specific types
TestServer.SSH.start(listen: [:exec, :data, :env, :pty])
```

Example handling env messages:

```elixir
{:ok, _} = TestServer.SSH.start(listen: [:exec, :data, :env])
{:ok, channel} = TestServer.SSH.channel()

TestServer.SSH.handle(channel,
  match: fn msg, _state -> elem(msg, 0) == :env end,
  to: fn {:env, _ch, _wr, var, val}, state ->
    {:ok, [{to_string(var), to_string(val)} | state || []]}
  end
)

TestServer.SSH.handle(channel,
  to: fn {:exec, _ch, _wr, command}, state ->
    {:reply, "env=#{inspect(state)}", state}
  end
)
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
{:ok, channel} = TestServer.SSH.channel()

TestServer.SSH.handle(channel,
  to: fn _msg, state -> {:reply, "first", state} end
)
TestServer.SSH.handle(channel,
  to: fn _msg, state -> {:reply, "second", state} end
)

# Client sends first command → matched by first handler
# Client sends second command → matched by second handler
```

### Multiple Instances

```elixir
{:ok, server_1} = TestServer.SSH.start()
{:ok, server_2} = TestServer.SSH.start()

TestServer.SSH.handle(to: fn _msg, state -> {:reply, "s1", state} end)
TestServer.SSH.handle(to: fn _msg, state -> {:reply, "s2", state} end)

{host, port_1} = TestServer.SSH.address(server_1)
{host, port_2} = TestServer.SSH.address(server_2)
```

<!-- MDOC !-->
