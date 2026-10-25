# UDP

<!-- MDOC !-->

Mock UDP datagram endpoints with DTLS support.

## Usage

Add data expectations with `TestServer.UDP.handle/2`:

```elixir
test "send/2" do
  # The test server will autostart the current test server, if not already
  # running, and a peer expectation will be set up if not already set.
  TestServer.UDP.handle()

  assert {:ok, socket} = UDPClient.open()
  assert UDPClient.send(socket, TestServer.UDP.address(), "echo") == :ok
  assert UDPClient.receive_data(socket) == {:ok, "echo"}
end
```

`TestServer.UDP.handle/2` can route data to an anonymous function:

```elixir
TestServer.UDP.handle(to: fn _data, state -> {:reply, "pong", state} end)
```

A custom match function can be set with the `:match` option:

```elixir
TestServer.UDP.handle(match: fn data, _state -> data == "ping" end)
```

Handlers are processed in the order they were added:

```elixir
TestServer.UDP.handle(to: fn _data, state -> {:reply, "first", state} end)
TestServer.UDP.handle(to: fn _data, state -> {:reply, "second", state} end)

assert {:ok, socket} = UDPClient.open()
assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
assert UDPClient.receive_data(socket) == {:ok, "first"}
assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
assert UDPClient.receive_data(socket) == {:ok, "second"}
```

Use `TestServer.UDP.send/2` to send data from the server to the peer:

```elixir
peer = TestServer.UDP.peer()

TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)

assert {:ok, socket} = UDPClient.open()
assert UDPClient.send(socket, TestServer.UDP.address(), "connect") == :ok

TestServer.UDP.send(peer, to: fn state -> {:reply, "ping", state} end)

assert UDPClient.receive_data(socket) == {:ok, "ping"}
```

Use `TestServer.UDP.peer/1` to expect multiple clients or use with `TestServer.UDP.send/2`. They are assigned in the order they are added:

```elixir
peer_1 = TestServer.UDP.peer()
peer_2 = TestServer.UDP.peer()

TestServer.UDP.handle(peer_1, to: fn _data, state -> {:reply, "peer 1", state} end)
TestServer.UDP.handle(peer_2, to: fn _data, state -> {:reply, "peer 2", state} end)

assert {:ok, socket_1} = UDPClient.open()
assert {:ok, socket_2} = UDPClient.open()
assert UDPClient.send(socket_2, TestServer.UDP.address(), "ping") == :ok
assert UDPClient.receive_data(socket_2) == {:ok, "peer 1"}
assert UDPClient.send(socket_1, TestServer.UDP.address(), "ping") == :ok
assert UDPClient.receive_data(socket_1) == {:ok, "peer 2"}
```

### DTLS

DTLS can be enabled with the `:transport` option when calling
`TestServer.UDP.start/1`. A self-signed certificate suite is automatically
generated:

```elixir
TestServer.UDP.start!(transport: :dtls)
TestServer.UDP.handle()

{host, port} = TestServer.UDP.address()

assert {:ok, socket} =
         :ssl.connect(String.to_charlist(host), port,
           protocol: :dtls,
           active: false,
           mode: :binary,
           verify: :verify_peer,
           cacerts: TestServer.UDP.cacerts(),
           server_name_indication: String.to_charlist(host),
           log_level: :warning
         )

assert :ssl.send(socket, "ping") == :ok
assert :ssl.recv(socket, 0) == {:ok, "ping"}
```

Custom certificates can be used by setting the `:tls` option:

```elixir
TestServer.UDP.start!(
  transport: :dtls,
  tls: [certfile: "cert.pem", keyfile: "key.pem"]
)
```

### IPv6

Use the `:ipfamily` option to test with IPv6:

```elixir
TestServer.UDP.start!(ipfamily: :inet6)
TestServer.UDP.handle()


assert {:ok, socket} = UDPClient.open(:inet6)
assert UDPClient.send(socket, TestServer.UDP.address(), "ping", :inet6) == :ok
assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, _port, "ping"}} = UDPClient.receive_data(socket)
```

### Example: DNS

The UDP test server can test a DNS client:

```elixir
test ":inet_res.lookup/5" do
  TestServer.UDP.handle(
    to: fn data, state ->
      assert {:ok, query} = :inet_dns.decode(data)
      assert header = :inet_dns.msg(query, :header)
      assert [question] = :inet_dns.msg(query, :qdlist)
      assert domain = :inet_dns.dns_query(question, :domain)
      assert domain == ~c"example.test"

      response =
        :inet_dns.make_msg(query,
          header: :inet_dns.make_header(header, qr: true, ra: true),
          anlist: [
            :inet_dns.make_rr(
              domain: domain,
              type: :a,
              class: :in,
              ttl: 60,
              data: {192, 0, 2, 1}
            )
          ]
        )

      {:reply, :inet_dns.encode(response), state}
    end
  )

  {_host, port} = TestServer.UDP.address()

  options = [
    nameservers: [{{127, 0, 0, 1}, port}],
    edns: false,
    retry: 1
  ]

  assert :inet_res.lookup(~c"example.test", :in, :a, options, 1_000) ==
           [{192, 0, 2, 1}]
end
```

<!-- MDOC !-->
