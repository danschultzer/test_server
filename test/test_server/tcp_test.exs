defmodule TestServer.TCPTest do
  use ExUnit.Case
  doctest TestServer.TCP

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias __MODULE__.{LogHandler, TCPClient, TLSClient}

  describe "start/1" do
    test "with invalid options" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.TCP.start(invalid: :option)
      end
    end

    test "with invalid `:transport` option" do
      assert_raise ArgumentError, ~r/expected :tcp or :tls transport, got: :invalid/, fn ->
        TestServer.TCP.start(transport: :invalid)
      end

      assert_raise ArgumentError, ~r/expected transport or list of transports, got: \[\]/, fn ->
        TestServer.TCP.start(transport: [])
      end

      assert_raise ArgumentError, ~r/expected :tcp or :tls transport, got: \[:tcp, :udp\]/, fn ->
        TestServer.TCP.start(transport: [:tcp, :udp])
      end
    end

    test "with invalid `:port` option" do
      assert_raise ArgumentError, ~r/expected a port, got: :invalid/, fn ->
        TestServer.TCP.start(port: :invalid)
      end
    end

    test "when port is in use" do
      instance = TestServer.TCP.start!()
      {_, port} = TestServer.TCP.address(instance)

      assert {:error, %RuntimeError{message: message}} = TestServer.TCP.start(port: port)
      assert message == "Could not listen to port #{port}, because: :eaddrinuse"
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, instance_2} = TestServer.TCP.start()

      refute instance_1 == instance_2

      {_, port_1} = TestServer.TCP.address(instance_1)
      {_, port_2} = TestServer.TCP.address(instance_2)

      refute port_1 == port_2
    end

    test "with `transport: :tls` option" do
      instance = TestServer.TCP.start!(transport: :tls)
      valid_cacerts = TestServer.TCP.cacerts()
      %{cacerts: invalid_cacerts} = X509.Test.Suite.new()
      options = TestServer.TCP.Instance.options(instance)

      assert Keyword.has_key?(options, :cacerts)

      assert {:error, {:tls_alert, _}} =
               TLSClient.connect(
                 TestServer.TCP.address(),
                 tls_options(invalid_cacerts)
               )

      TestServer.TCP.handle()

      assert {:ok, socket} =
               TLSClient.connect(
                 TestServer.TCP.address(),
                 tls_options(valid_cacerts)
               )

      assert TLSClient.send(socket, "ping") == :ok
      assert TLSClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with `transport: :tls` option with `:tls` option with custom certificates" do
      options = TestServer.put_tls_options([])
      tls = Keyword.fetch!(options, :tls)
      cacerts = Keyword.fetch!(options, :cacerts)
      tls = Keyword.put(tls, :alpn_preferred_protocols, ["test"])
      instance = TestServer.TCP.start!(transport: :tls, tls: tls)
      options = TestServer.TCP.Instance.options(instance)

      refute Keyword.has_key?(options, :cacerts)

      TestServer.TCP.handle()

      tls_options = Keyword.put(tls_options(cacerts), :alpn_advertised_protocols, ["test"])

      assert {:ok, socket} = TLSClient.connect(TestServer.TCP.address(), tls_options)
      assert :ssl.negotiated_protocol(socket) == {:ok, "test"}
      assert TLSClient.send(socket, "ping") == :ok
      assert TLSClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with `transport: :tls` option with `:tls` option with handshake extensions" do
      TestServer.TCP.start!(transport: :tls, tls: [handshake: :hello])
      TestServer.TCP.handle()

      assert {:ok, socket} = TLSClient.connect(TestServer.TCP.address(), tls_options())
      assert TLSClient.send(socket, "ping") == :ok
      assert TLSClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with `ipfamily: :inet6` option" do
      instance = TestServer.TCP.start!(ipfamily: :inet6)
      :ok = TestServer.TCP.handle()
      options = TestServer.TCP.Instance.options(instance)
      listener = Keyword.fetch!(options, :listener)

      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 0}, _port}} = :inet.sockname(listener)
      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address(), [:inet6])
      assert TCPClient.send(socket, "ping") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "ping"}
      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, _port}} = :inet.peername(socket)
    end

    test "when listener socket is closed" do
      instance = TestServer.TCP.start!()
      options = TestServer.TCP.Instance.options(instance)
      acceptor = Keyword.fetch!(options, :acceptor)
      listener = Keyword.fetch!(options, :listener)
      monitor = Process.monitor(acceptor)

      # This triggers the {:error, :closed} code path for normal shutdown
      assert TCPClient.close(listener) == :ok
      assert_receive {:DOWN, ^monitor, :process, ^acceptor, :normal}
    end

    test "when test ends" do
      {:ok, port} = TestServer.open_port([])

      on_exit(fn ->
        refute :gen_tcp.listen(port, []) == {:error, :eaddrinuse},
               "Port #{port} must be released after test ends"
      end)

      assert {:ok, _instance} = TestServer.TCP.start(port: port)
      assert {:error, :eaddrinuse} = :gen_tcp.listen(port, [])
    end
  end

  describe "start!/1" do
    test "returns instance" do
      assert instance = TestServer.TCP.start!()
      assert is_pid(instance)
    end

    test "when start fails" do
      instance = TestServer.TCP.start!()
      port = instance |> TestServer.TCP.Instance.options() |> Keyword.fetch!(:port)

      assert_raise RuntimeError,
                   ~r/EXIT when starting TestServer.TCP instance on port #{port}/,
                   fn -> TestServer.TCP.start!(port: port) end
    end
  end

  describe "stop/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.TCP.Instance running", fn ->
        TestServer.TCP.stop()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.TCP.start!()
                     :ok = TestServer.TCP.stop()

                     TestServer.TCP.stop(instance)
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, _instance_2} = TestServer.TCP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.stop\/0`/,
                   fn -> TestServer.TCP.stop() end

      assert TestServer.TCP.stop(instance_1) == :ok
      assert TestServer.TCP.stop() == :ok
    end

    test "when started with `transport: :tcp` option" do
      instance = TestServer.TCP.start!(transport: :tcp)
      connection = TestServer.TCP.connection()
      address = TestServer.TCP.address()
      {:ok, socket} = TCPClient.connect(address)
      :ok = TestServer.TCP.send(connection)
      {:ok, "ping"} = TCPClient.receive_data(socket)
      [%{owner: owner}] = TestServer.TCP.Instance.connections(instance)
      monitor = Process.monitor(owner)

      assert TestServer.TCP.stop() == :ok

      refute Process.alive?(instance)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
      assert {:error, :econnrefused} = TCPClient.connect(address)
      assert {:error, :closed} = TCPClient.receive_data(socket, 0)
    end

    test "when started with `transport: :tls` option" do
      instance = TestServer.TCP.start!(transport: :tls)
      connection = TestServer.TCP.connection()
      address = TestServer.TCP.address()
      tls_options = tls_options()
      {:ok, socket} = TLSClient.connect(address, tls_options)
      :ok = TestServer.TCP.send(connection)
      {:ok, "ping"} = TLSClient.receive_data(socket)
      [%{owner: owner}] = TestServer.TCP.Instance.connections(instance)
      monitor = Process.monitor(owner)

      assert TestServer.TCP.stop() == :ok

      refute Process.alive?(instance)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
      assert {:error, :econnrefused} = TLSClient.connect(address, tls_options)
      assert {:error, :closed} = TLSClient.receive_data(socket)
    end
  end

  describe "address/2" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.TCP.Instance running", fn ->
        TestServer.TCP.address()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.TCP.start!()
                     :ok = TestServer.TCP.stop()

                     TestServer.TCP.address(instance)
                   end
    end

    test "with multiple instances" do
      instance_1 = TestServer.TCP.start!()
      instance_2 = TestServer.TCP.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.address\/1`/,
                   fn -> TestServer.TCP.address() end

      refute TestServer.TCP.address(instance_1) == TestServer.TCP.address(instance_2)
    end

    test "with invalid options" do
      TestServer.TCP.start!()

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.TCP.address(invalid: :option)
      end
    end

    test "returns" do
      TestServer.TCP.start!()

      assert {"localhost", port} = TestServer.TCP.address()
      assert is_integer(port)
    end

    test "with invalid `:host` option" do
      TestServer.TCP.start!()

      assert_raise RuntimeError, ~r/Invalid host, got: :invalid/, fn ->
        TestServer.TCP.address(host: :invalid)
      end
    end

    test "with `:host` option" do
      TestServer.TCP.start!()

      assert {"custom-host", _port} = TestServer.TCP.address(host: "custom-host")
    end

    test "with `:host` option when started with `ipfamily: :inet6` option" do
      TestServer.TCP.start!(ipfamily: :inet6)
      TestServer.TCP.handle()

      assert address = TestServer.TCP.address(host: "custom-host")
      assert {:ok, socket} = TCPClient.connect(address, [:inet6])

      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, _port}} = :inet.peername(socket)
      assert TCPClient.send(socket, "ping") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "ping"}
    end
  end

  describe "cacerts/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.TCP.Instance running", fn ->
        TestServer.TCP.cacerts()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.TCP.start!()
                     :ok = TestServer.TCP.stop()

                     TestServer.TCP.cacerts(instance)
                   end
    end

    test "when not started with `transport: :tls` option" do
      TestServer.TCP.start!()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running with `\[transport: :tls\]` or `\[transport: \[:tcp, :tls\]\]` options/,
                   fn -> TestServer.TCP.cacerts() end
    end

    test "when started with `scheme: :https` option with `:tls` option with custom certificates" do
      tls_options = [] |> TestServer.put_tls_options() |> Keyword.fetch!(:tls)

      TestServer.TCP.start!(transport: :tls, tls: tls_options)

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is running with custom `:tls` certificate options/,
                   fn -> TestServer.TCP.cacerts() end
    end
  end

  describe "connection/1" do
    test "when instance not running" do
      instance = TestServer.TCP.start!()
      :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn -> TestServer.TCP.connection(instance) end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, _instance_2} = TestServer.TCP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.connection\/0`/,
                   fn -> TestServer.TCP.connection() end

      assert TestServer.TCP.connection(instance_1)

      :ok = TestServer.TCP.stop(instance_1)
    end

    test "when no socket received" do
      defmodule ConnectionNoSocketReceivedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.connection()
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "has connections that were not used:"
    end

    test "when receiving an unexpected socket" do
      defmodule ConnectionNoConnectionsTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), ConnectionNoConnectionsTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected TCP connection attempt"
      assert io =~ "No connections registered."
      refute io =~ "The following connections were registered:"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when receiving unexpected socket after used connections" do
      defmodule ConnectionUnexpectedConnectionAfterUsedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle()

          assert {:ok, _socket_1} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, socket_2} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.receive_data(socket_2)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), ConnectionUnexpectedConnectionAfterUsedTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected TCP connection attempt"
      refute io =~ "No connections registered."
      assert io =~ "The following connections were registered:"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "with multiple connections" do
      connection_1 = TestServer.TCP.connection()
      connection_2 = TestServer.TCP.connection()

      TestServer.TCP.handle(connection_1,
        to: fn _data, state -> {:reply, "connection 1", state} end
      )

      TestServer.TCP.handle(connection_2,
        to: fn _data, state -> {:reply, "connection 2", state} end
      )

      assert {:ok, socket_1} = TCPClient.connect(TestServer.TCP.address())
      assert {:ok, socket_2} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket_2, "ping") == :ok
      assert TCPClient.send(socket_1, "ping") == :ok
      assert TCPClient.receive_data(socket_1) == {:ok, "connection 1"}
      assert TCPClient.receive_data(socket_2) == {:ok, "connection 2"}
    end
  end

  describe "handle/2" do
    test "with multiple instances" do
      TestServer.TCP.start!()
      TestServer.TCP.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.handle\/1`/,
                   fn -> TestServer.TCP.handle() end
    end

    test "with multiple connections" do
      TestServer.TCP.connection()
      TestServer.TCP.connection()

      assert_raise RuntimeError,
                   ~r/Multiple connections available, please pass connection to `TestServer\.TCP\.handle\/2`/,
                   fn -> TestServer.TCP.handle() end

      TestServer.TCP.stop()
    end

    test "when connection instance not running" do
      connection = TestServer.TCP.connection()
      :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn -> TestServer.TCP.handle(connection) end
    end

    test "with invalid options" do
      connection = TestServer.TCP.connection()

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.TCP.handle(connection, invalid: :option)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.handle(connection, to: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.handle(connection, match: :invalid)
      end

      TestServer.TCP.stop()
    end

    test "when no data received" do
      defmodule HandleNoDataTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.handle()

          assert {:ok, _socket} = TCPClient.connect(TestServer.TCP.address())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "did not receive data for these handlers before the test ended"
    end

    test "when receiving unexpected data" do
      defmodule HandleUnexpectedDataTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.connection()

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "ping") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleUnexpectedDataTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected TCP data"
      assert io =~ "No active handlers."
      refute io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when receiving unexpected data before all handlers are processed" do
      defmodule HandleUnexpectedDataBeforeProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(match: fn _data, _state -> false end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "ping") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
          :ok = TestServer.TCP.stop()
        end
      end

      Process.register(self(), HandleUnexpectedDataBeforeProcessedTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected TCP data"
      assert io =~ "Active handlers:"
      refute io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when receiving unexpected data after all handlers are processed" do
      defmodule HandleUnexpectedDataAfterProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle()

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "first") == :ok
          assert TCPClient.receive_data(socket) == {:ok, "first"}
          assert TCPClient.send(socket, "second") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleUnexpectedDataAfterProcessedTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected TCP data"
      assert io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "with no existing connection" do
      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with existing connection" do
      TestServer.TCP.connection()
      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "ping"}
    end

    # It's not possible to test actual TCP errors in a controlled manner so
    # we simulate it by sending a :tcp_error message to the owner process
    test "when receiving :tcp_error" do
      defmodule HandleTCPErrorTest do
        use ExUnit.Case

        test "fails" do
          instance = TestServer.TCP.start!(suppress_warning: true)
          connection = TestServer.TCP.connection()

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TestServer.TCP.send(connection) == :ok
          assert TCPClient.receive_data(socket) == {:ok, "ping"}

          assert [%{owner: owner, socket: {:tcp, raw_socket}}] =
                   TestServer.TCP.Instance.connections(instance)

          send(owner, {:tcp_error, raw_socket, :test})
          assert {:ok, data} = TCPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleTCPErrorTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "TCP receive failed, because: :test"
      assert_receive {:data, data}
      assert data =~ "TCP receive failed, because: :test"
    end

    # It's not possible to test actual SSL errors in a controlled manner so
    # we simulate it by sending a :ssl_error message to the owner process
    test "when receiving :ssl_error" do
      defmodule HandleSSLErrorTest do
        use ExUnit.Case

        test "fails" do
          instance = TestServer.TCP.start!(transport: :tls, suppress_warning: true)
          connection = TestServer.TCP.connection()

          assert {:ok, socket} =
                   TLSClient.connect(TestServer.TCP.address(), unquote(__MODULE__).tls_options())

          assert TestServer.TCP.send(connection) == :ok
          assert TLSClient.receive_data(socket) == {:ok, "ping"}

          assert [%{owner: owner, socket: {:tls, raw_socket}}] =
                   TestServer.TCP.Instance.connections(instance)

          send(owner, {:ssl_error, raw_socket, :test})
          assert {:ok, data} = TLSClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleSSLErrorTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "TCP receive failed, because: :test"
      assert_receive {:data, data}
      assert data =~ "TCP receive failed, because: :test"
    end

    test "when `:to` function raises exception" do
      defmodule HandleToFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(to: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "ping") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)
          assert TCPClient.receive_data(socket) == {:error, :closed}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.TCPTest.HandleToFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when `:to` function returns an invalid response" do
      defmodule HandleToInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(to: fn _data, _state -> :invalid end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "ping") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToInvalidResponseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "with `:to` function returning `{:reply, data, state}` with invalid data" do
      defmodule HandleToReplyResponseInvalidDataTest do
        use ExUnit.Case

        test "fails" do
          LogHandler.setup()
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(to: fn _data, state -> {:reply, :not_iodata, state} end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "ping") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)

          # Wait for log to print
          assert_receive {:log, _msg}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToReplyResponseInvalidDataTest)

      assert io =
               capture_io(fn ->
                 log = capture_log(fn -> ExUnit.run() end)

                 send(self(), {:log, log})
               end)

      assert io =~ "TCP reply failed, because:"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
      assert_received {:log, log}
      assert log =~ "Bad value on output port 'tcp_inet'"
    end

    test "with `:to` function returning `{:reply, data, state}`" do
      TestServer.TCP.start!()
      TestServer.TCP.handle(to: fn _data, state -> {:reply, ["PO", [?N], "G"], state} end)

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "PONG"}
    end

    test "when `:to` function returns `{:reply, {data, options}, state}` with invalid reply options" do
      defmodule HandleToReplyResponseInvalidReplyOptionsTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)

          TestServer.TCP.handle(
            to: fn _data, state -> {:reply, {"pong", invalid: true}, state} end
          )

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "ping") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)
          assert TCPClient.receive_data(socket) == {:error, :closed}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToReplyResponseInvalidReplyOptionsTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "Invalid options in callback response, got: [invalid: true]"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when `:to` function returns `{:reply, {data, options}, state}` with invalid upgrade options" do
      defmodule HandleToReplyResponseInvalidUpgradeOptionsTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)

          TestServer.TCP.handle(
            to: fn _data, state -> {:reply, {"pong", upgrade: :udp}, state} end
          )

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "ping") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)
          assert TCPClient.receive_data(socket) == {:error, :closed}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToReplyResponseInvalidUpgradeOptionsTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "TCP transport can only upgrade from TCP to TLS, got: :tcp to :udp"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when `:to` function returns `{:reply, {data, options}, state}` with reply option `upgrade: :tls` when no TLS transport" do
      defmodule HandleToReplyResponseNoTLSTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true, transport: :tcp)

          TestServer.TCP.handle(
            to: fn _data, state -> {:reply, {"upgrade", upgrade: :tls}, state} end
          )

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "upgrade") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)
          assert TCPClient.receive_data(socket) == {:error, :closed}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToReplyResponseNoTLSTest)

      assert io = capture_io(fn -> ExUnit.run() end)

      assert io =~
               "TCP transport can't upgrade to TLS without `transport: [:tcp, :tls]` option"

      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when `:to` function returns `{:reply, {data, options}, state}` with reply option `upgrade: :tls` when invalid transport switch" do
      defmodule HandleToReplyResponseInvalidTransportSwitchTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(transport: :tls, suppress_warning: true)

          TestServer.TCP.handle(
            to: fn _data, state -> {:reply, {"upgrade", upgrade: :tls}, state} end
          )

          assert {:ok, socket} =
                   TLSClient.connect(TestServer.TCP.address(), unquote(__MODULE__).tls_options())

          assert TLSClient.send(socket, "upgrade") == :ok
          assert {:ok, data} = TLSClient.receive_data(socket)
          assert {:error, :closed} = TLSClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToReplyResponseInvalidTransportSwitchTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "TCP transport can only upgrade from TCP to TLS, got: :tls to :tls"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when `:to` function returns `{:reply, {data, options}, state}` with reply option `upgrade: :tls` when client disconnects during handshake" do
      defmodule HandleToReplyResponseHandshakeFailsTest do
        use ExUnit.Case

        test "fails" do
          instance = TestServer.TCP.start!(transport: [:tcp, :tls], suppress_warning: true)

          TestServer.TCP.handle(
            to: fn _data, state -> {:reply, {"upgrade", upgrade: :tls}, state} end
          )

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "upgrade") == :ok
          assert TCPClient.receive_data(socket) == {:ok, "upgrade"}
          assert [%{owner: owner}] = TestServer.TCP.Instance.connections(instance)
          assert monitor = Process.monitor(owner)
          assert TCPClient.close(socket) == :ok
          assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "TCP transport upgrade failed, because: :closed"
    end

    test "when `:to` function returns `{:reply, {data, options}, state}` with reply option `upgrade: :tls`" do
      # The transport is in reverse to ensure that order doesn't matter
      TestServer.TCP.start!(transport: [:tls, :tcp])

      TestServer.TCP.handle(
        to: fn "upgrade", state -> {:reply, {"upgrade", upgrade: :tls}, state} end
      )

      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "upgrade") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "upgrade"}
      assert {:ok, socket} = TLSClient.upgrade(socket, tls_options())
      assert TLSClient.send(socket, "ping") == :ok
      assert TLSClient.receive_data(socket) == {:ok, "ping"}
    end

    test "when `:to` function returns `{:reply, {data, options}, state}` with reply option `upgrade: :tls` with TLS handshake extensions" do
      TestServer.TCP.start!(transport: [:tcp, :tls], tls: [handshake: :hello])

      TestServer.TCP.handle(
        to: fn "upgrade", state -> {:reply, {"upgrade", upgrade: :tls}, state} end
      )

      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "upgrade") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "upgrade"}
      assert {:ok, socket} = TLSClient.upgrade(socket, tls_options())
      assert TLSClient.send(socket, "ping") == :ok
      assert TLSClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with `:to` function returning `{:ok, state}`" do
      TestServer.TCP.start!(listen: [packet: :line])
      TestServer.TCP.handle(to: fn _data, state -> {:ok, Map.put(state, :a, 1)} end)
      TestServer.TCP.handle(to: fn _data, state -> {:reply, inspect(state), state} end)

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping\r\n") == :ok
      assert TCPClient.send(socket, "ping\r\n") == :ok
      assert TCPClient.receive_data(socket) == {:ok, inspect(%{a: 1})}
    end

    test "when `:match` function raises exception" do
      defmodule HandleMatchFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(match: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "ping") == :ok
          assert {:ok, data} = TCPClient.receive_data(socket)
          assert TCPClient.receive_data(socket) == {:error, :closed}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleMatchFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.TCPTest.HandleMatchFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "with `:match` function" do
      TestServer.TCP.handle(
        match: fn data, _state -> data == "pong" end,
        to: fn _data, state -> {:reply, "1", state} end
      )

      TestServer.TCP.handle(to: fn _data, state -> {:reply, "2", state} end)

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "2"}
      assert TCPClient.send(socket, "pong") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "1"}
    end
  end

  describe "send/2" do
    test "when connection instance not running" do
      connection = TestServer.TCP.connection()
      :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn -> TestServer.TCP.send(connection) end
    end

    test "with invalid options" do
      connection = TestServer.TCP.connection()

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.TCP.send(connection, invalid: :option)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.send(connection, to: :invalid)
      end

      assert_raise ArgumentError, ~r/expected positive integer, got: :invalid/, fn ->
        TestServer.TCP.send(connection, timeout: :invalid)
      end

      assert_raise ArgumentError, ~r/expected positive integer, got: 0/, fn ->
        TestServer.TCP.send(connection, timeout: 0)
      end

      assert_raise ArgumentError, ~r/expected positive integer, got: -1/, fn ->
        TestServer.TCP.send(connection, timeout: -1)
      end

      TestServer.TCP.stop()
    end

    test "when connection doesn't exist" do
      instance = TestServer.TCP.start!()

      assert_raise RuntimeError,
                   ~r/cannot send to the connection, because the connection does not exist/,
                   fn -> TestServer.TCP.send({instance, make_ref()}) end
    end

    test "when client has not connected" do
      connection = TestServer.TCP.connection()

      assert_raise RuntimeError,
                   ~r/cannot send to the connection, because no client has connected to it/,
                   fn -> TestServer.TCP.send(connection, timeout: 1) end

      TestServer.TCP.stop()
    end

    test "when client has disconnected" do
      instance = TestServer.TCP.start!()
      connection = TestServer.TCP.connection()
      :ok = TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "ping"}
      assert [%{owner: owner}] = TestServer.TCP.Instance.connections(instance)
      assert monitor = Process.monitor(owner)
      assert TCPClient.close(socket) == :ok
      assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}

      assert_raise RuntimeError,
                   ~r/cannot send to the connection, because client has disconnected/,
                   fn -> TestServer.TCP.send(connection) end
    end

    test "when started with `transport: :tls` when client has disconnected" do
      instance = TestServer.TCP.start!(transport: :tls)
      connection = TestServer.TCP.connection()
      :ok = TestServer.TCP.handle()

      assert {:ok, socket} = TLSClient.connect(TestServer.TCP.address(), tls_options())
      assert TLSClient.send(socket, "ping") == :ok
      assert TLSClient.receive_data(socket) == {:ok, "ping"}
      assert [%{owner: owner}] = TestServer.TCP.Instance.connections(instance)
      assert monitor = Process.monitor(owner)
      assert TLSClient.close(socket) == :ok
      assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}

      assert_raise RuntimeError,
                   ~r/cannot send to the connection, because client has disconnected/,
                   fn -> TestServer.TCP.send(connection) end
    end

    test "when connection is not yet accepted" do
      instance = TestServer.TCP.start!()
      connection = TestServer.TCP.connection(instance)

      send_task =
        Task.async(fn ->
          TestServer.TCP.send(connection, to: fn state -> {:reply, "pong", state} end)
        end)

      wait_until(fn ->
        [%{subscribers: subscribers}] = TestServer.TCP.Instance.connections(instance)

        length(subscribers) == 1
      end)

      refute Task.yield(send_task, 0)
      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert Task.await(send_task) == :ok
      assert TCPClient.receive_data(socket, 0) == {:ok, "pong"}
    end

    test "when timeout received after connection is accepted" do
      instance = TestServer.TCP.start!()
      connection = TestServer.TCP.connection(instance)
      {:ok, _socket} = TCPClient.connect(TestServer.TCP.address(instance))

      assert TestServer.TCP.send(connection, to: fn state -> {:ok, state} end) == :ok

      tag = make_ref()
      from = {self(), tag}

      send(instance, {:timeout, from, {:send, 0}})

      assert [_connection] = TestServer.TCP.Instance.connections(instance)
      refute_receive {^tag, {:error, :enotconn}}
    end

    test "sends" do
      connection = TestServer.TCP.connection()
      {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

      TestServer.TCP.send(connection)

      assert TCPClient.receive_data(socket) == {:ok, "ping"}
    end

    test "when `:to` function raises exception" do
      defmodule SendToFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          _instance = TestServer.TCP.start!(suppress_warning: true)
          connection = TestServer.TCP.connection()
          {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

          TestServer.TCP.send(connection, to: fn _state -> raise "boom" end)

          assert {:ok, data} = TCPClient.receive_data(socket)
          assert TCPClient.receive_data(socket) == {:error, :closed}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), SendToFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.TCPTest.SendToFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when `:to` function returns an invalid response" do
      defmodule SendToInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          _instance = TestServer.TCP.start!(suppress_warning: true)
          connection = TestServer.TCP.connection()

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

          TestServer.TCP.send(connection, to: fn _state -> :invalid end)

          assert {:ok, data} = TCPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), SendToInvalidResponseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
    end

    test "when `:to` function returns `{:reply, data, state}` with invalid data" do
      defmodule SendToReplyResponseInvalidDataTest do
        use ExUnit.Case

        test "fails" do
          :ok = LogHandler.setup()
          _instance = TestServer.TCP.start(suppress_warning: true)
          connection = TestServer.TCP.connection()

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

          TestServer.TCP.send(connection, to: fn state -> {:reply, :not_iodata, state} end)

          assert {:ok, data} = TCPClient.receive_data(socket)

          assert_receive {:log, _msg}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), SendToReplyResponseInvalidDataTest)

      assert io =
               capture_io(fn ->
                 log = capture_log(fn -> ExUnit.run() end)

                 send(self(), {:log, log})
               end)

      assert io =~ "TCP reply failed, because:"
      assert_receive {:data, data}
      assert_io_tcp_data(io, data)
      assert_received {:log, log}
      assert log =~ "Bad value on output port 'tcp_inet'"
    end

    test "when `:to` function returns `{:reply, data, state}`" do
      connection = TestServer.TCP.connection()
      {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

      TestServer.TCP.send(connection, to: fn state -> {:reply, ["PO", [?N], "G"], state} end)

      assert TCPClient.receive_data(socket) == {:ok, "PONG"}
    end

    test "when `:to` function returns `{:ok, state}`" do
      connection = TestServer.TCP.connection()
      {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

      TestServer.TCP.send(connection, to: fn state -> {:ok, Map.put(state, :a, 1)} end)
      TestServer.TCP.send(connection, to: fn state -> {:reply, inspect(state), state} end)

      assert TCPClient.receive_data(socket) == {:ok, inspect(%{a: 1})}
    end
  end

  defp wait_until(fun) do
    case fun.() do
      true ->
        :ok

      false ->
        :timer.sleep(1)
        wait_until(fun)
    end
  end

  def tls_options, do: tls_options(TestServer.TCP.cacerts())

  def tls_options(cacerts) do
    {host, _port} = TestServer.TCP.address()

    [
      verify: :verify_peer,
      cacerts: cacerts,
      server_name_indication: String.to_charlist(host),
      log_level: :warning
    ]
  end

  defmodule TCPClient do
    def connect({host, port}, options \\ []) do
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false] ++ options)
    end

    def send(socket, data) do
      :gen_tcp.send(socket, data)
    end

    def receive_data(socket, length \\ 0) do
      :gen_tcp.recv(socket, length)
    end

    def close(socket) do
      :gen_tcp.close(socket)
    end
  end

  defmodule TLSClient do
    def connect({host, port}, options) do
      :ssl.connect(String.to_charlist(host), port, [:binary, active: false] ++ options)
    end

    def send(socket, data) do
      :ssl.send(socket, data)
    end

    def receive_data(socket, length \\ 0) do
      :ssl.recv(socket, length)
    end

    def close(socket) do
      :ssl.close(socket)
    end

    def upgrade(tcp_socket, options) do
      :ssl.connect(tcp_socket, [:binary, active: false] ++ options)
    end
  end

  defmodule LogHandler do
    @behaviour :logger_handler

    def setup do
      logger_id = __MODULE__
      formatter = Logger.default_formatter()
      :ok = :logger.add_handler(logger_id, __MODULE__, %{test_pid: self(), formatter: formatter})

      ExUnit.Callbacks.on_exit(fn ->
        :ok = :logger.remove_handler(logger_id)
      end)
    end

    @impl true
    def adding_handler(config), do: {:ok, config}

    @impl true
    def removing_handler(_config), do: :ok

    @impl true
    def changing_config(_set_or_update, _old, new), do: {:ok, new}

    @impl true
    def log(event, %{test_pid: test_pid, formatter: {mod, config}}) do
      message = mod.format(event, config)

      send(test_pid, {:log, to_string(message)})

      :ok
    end
  end

  defp assert_io_tcp_data(io, message) do
    assert normalize_exception_message(io) =~ normalize_exception_message(message)
  end

  defp normalize_exception_message(message) do
    message
    |> String.replace(~r/\e\[[0-9;]*[mK]/, "")
    |> String.replace(~r/\n\s*stacktrace:\s*\n/, "\n")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
