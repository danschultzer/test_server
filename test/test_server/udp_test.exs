defmodule TestServer.UDPTest do
  use ExUnit.Case
  doctest TestServer.UDP

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias __MODULE__.{LogHandler, DTLSClient, UDPClient}

  describe "start/1" do
    test "with invalid options" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.UDP.start(invalid: :option)
      end
    end

    test "with invalid `:transport` option" do
      assert_raise ArgumentError, ~r/expected :udp or :dtls transport, got: :invalid/, fn ->
        TestServer.UDP.start(transport: :invalid)
      end
    end

    test "with invalid `:port` option" do
      assert_raise ArgumentError, ~r/expected a port, got: :invalid/, fn ->
        TestServer.UDP.start(port: :invalid)
      end
    end

    test "when port is in use" do
      instance = TestServer.UDP.start!()
      {_, port} = TestServer.UDP.address(instance)

      assert {:error, %RuntimeError{message: message}} = TestServer.UDP.start(port: port)
      assert message == "Could not listen to port #{port}, because: :eaddrinuse"
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.UDP.start()
      {:ok, instance_2} = TestServer.UDP.start()

      refute instance_1 == instance_2

      {_, port_1} = TestServer.UDP.address(instance_1)
      {_, port_2} = TestServer.UDP.address(instance_2)

      refute port_1 == port_2
    end

    test "with `transport: :dtls` option" do
      instance = TestServer.UDP.start!(transport: :dtls)
      valid_cacerts = TestServer.UDP.cacerts()
      %{cacerts: invalid_cacerts} = X509.Test.Suite.new(key_type: {:ec, :secp256r1})
      options = TestServer.UDP.Instance.options(instance)

      assert Keyword.has_key?(options, :cacerts)

      assert {:error, {:tls_alert, _}} =
               DTLSClient.connect(TestServer.UDP.address(), tls_options(invalid_cacerts))

      TestServer.UDP.handle()

      assert {:ok, socket} =
               DTLSClient.connect(TestServer.UDP.address(), tls_options(valid_cacerts))

      assert DTLSClient.send(socket, "ping") == :ok
      assert DTLSClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with `transport: :dtls` option with `:tls` option with custom certificates" do
      options = TestServer.put_tls_options([], {:ec, :secp256r1})
      tls = Keyword.fetch!(options, :tls)
      cacerts = Keyword.fetch!(options, :cacerts)
      tls = Keyword.put(tls, :alpn_preferred_protocols, ["test"])
      instance = TestServer.UDP.start!(transport: :dtls, tls: tls)
      options = TestServer.UDP.Instance.options(instance)

      refute Keyword.has_key?(options, :cacerts)

      TestServer.UDP.handle()

      tls_options = Keyword.put(tls_options(cacerts), :alpn_advertised_protocols, ["test"])

      assert {:ok, socket} = DTLSClient.connect(TestServer.UDP.address(), tls_options)
      assert :ssl.negotiated_protocol(socket) == {:ok, "test"}
      assert DTLSClient.send(socket, "ping") == :ok
      assert DTLSClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with `transport: :dtls` option with `:tls` option with handshake extensions" do
      TestServer.UDP.start!(transport: :dtls, tls: [handshake: :hello])
      TestServer.UDP.handle()

      assert {:ok, socket} = DTLSClient.connect(TestServer.UDP.address(), tls_options())
      assert DTLSClient.send(socket, "ping") == :ok
      assert DTLSClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with `ipfamily: :inet6` option" do
      instance = TestServer.UDP.start!(ipfamily: :inet6)
      :ok = TestServer.UDP.handle()
      options = TestServer.UDP.Instance.options(instance)
      listener = Keyword.fetch!(options, :listener)

      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 0}, _port}} = :inet.sockname(listener)
      assert {:ok, socket} = UDPClient.open(:inet6)
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping", :inet6) == :ok
      assert {:ok, data} = UDPClient.receive_data(socket, :raw)
      assert {{0, 0, 0, 0, 0, 0, 0, 1}, _server_port, "ping"} = data
      assert {:ok, {_client_address, client_port}} = :inet.sockname(socket)
      assert [%{socket: socket}] = TestServer.UDP.Instance.peers(instance)
      assert {:udp, ^listener, {0, 0, 0, 0, 0, 0, 0, 1}, ^client_port} = socket
    end

    test "when listener socket is closed" do
      instance = TestServer.UDP.start!()
      options = TestServer.UDP.Instance.options(instance)
      receiver = Keyword.fetch!(options, :receiver)
      listener = Keyword.fetch!(options, :listener)
      monitor = Process.monitor(receiver)

      # This triggers the {:error, :closed} code path for normal shutdown
      assert :gen_udp.close(listener) == :ok
      assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}
    end

    test "with `transport: :dtls` option when listener socket is closed" do
      instance = TestServer.UDP.start!(transport: :dtls)
      options = TestServer.UDP.Instance.options(instance)
      receiver = Keyword.fetch!(options, :receiver)
      listener = Keyword.fetch!(options, :listener)
      monitor = Process.monitor(receiver)

      # This triggers the {:error, :closed} code path for normal shutdown
      assert :ssl.close(listener) == :ok
      assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}
    end

    test "when test ends" do
      {:ok, socket} = :gen_udp.open(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_udp.close(socket)

      on_exit(fn ->
        refute :gen_udp.open(port, []) == {:error, :eaddrinuse},
               "Port #{port} must be released after test ends"
      end)

      assert {:ok, _instance} = TestServer.UDP.start(port: port)
      assert {:error, :eaddrinuse} = :gen_udp.open(port, [])
    end
  end

  describe "start!/1" do
    test "returns instance" do
      assert instance = TestServer.UDP.start!()
      assert is_pid(instance)
    end

    test "when start fails" do
      instance = TestServer.UDP.start!()
      port = instance |> TestServer.UDP.Instance.options() |> Keyword.fetch!(:port)

      assert_raise RuntimeError,
                   ~r/EXIT when starting TestServer.UDP instance on port #{port}/,
                   fn -> TestServer.UDP.start!(port: port) end
    end
  end

  describe "stop/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.UDP.Instance running", fn ->
        TestServer.UDP.stop()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.UDP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.UDP.start!()
                     :ok = TestServer.UDP.stop()

                     TestServer.UDP.stop(instance)
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.UDP.start()
      {:ok, _instance_2} = TestServer.UDP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.UDP\.stop\/0`/,
                   fn -> TestServer.UDP.stop() end

      assert TestServer.UDP.stop(instance_1) == :ok
      assert TestServer.UDP.stop() == :ok
    end

    test "when started with `transport: :udp` option" do
      instance = TestServer.UDP.start!(transport: :udp)
      peer = TestServer.UDP.peer()
      :ok = TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)
      address = TestServer.UDP.address()
      {:ok, socket} = UDPClient.open()
      :ok = UDPClient.send(socket, address, "ping")
      :ok = TestServer.UDP.send(peer)
      {:ok, "ping"} = UDPClient.receive_data(socket)
      [%{owner: owner}] = TestServer.UDP.Instance.peers(instance)
      monitor = Process.monitor(owner)

      assert TestServer.UDP.stop() == :ok

      refute Process.alive?(instance)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
      assert UDPClient.send(socket, address, "ping") == :ok
      assert UDPClient.receive_data(socket, 10) == {:error, :timeout}
    end

    test "when started with `transport: :dtls` option" do
      instance = TestServer.UDP.start!(transport: :dtls)
      peer = TestServer.UDP.peer()
      address = TestServer.UDP.address()
      tls_options = tls_options()
      {:ok, socket} = DTLSClient.connect(address, tls_options)
      :ok = TestServer.UDP.send(peer)
      {:ok, "ping"} = DTLSClient.receive_data(socket)
      [%{owner: owner}] = TestServer.UDP.Instance.peers(instance)
      monitor = Process.monitor(owner)

      assert TestServer.UDP.stop() == :ok

      refute Process.alive?(instance)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
      assert {:error, :timeout} = DTLSClient.connect(address, tls_options, 10)
      assert {:error, :closed} = DTLSClient.receive_data(socket)
    end
  end

  describe "address/2" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.UDP.Instance running", fn ->
        TestServer.UDP.address()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.UDP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.UDP.start!()
                     :ok = TestServer.UDP.stop()

                     TestServer.UDP.address(instance)
                   end
    end

    test "with multiple instances" do
      instance_1 = TestServer.UDP.start!()
      instance_2 = TestServer.UDP.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.UDP\.address\/1`/,
                   fn -> TestServer.UDP.address() end

      refute TestServer.UDP.address(instance_1) == TestServer.UDP.address(instance_2)
    end

    test "with invalid options" do
      TestServer.UDP.start!()

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.UDP.address(invalid: :option)
      end
    end

    test "returns" do
      TestServer.UDP.start!()

      assert {"localhost", port} = TestServer.UDP.address()
      assert is_integer(port)
    end

    test "with invalid `:host` option" do
      TestServer.UDP.start!()

      assert_raise RuntimeError, ~r/Invalid host, got: :invalid/, fn ->
        TestServer.UDP.address(host: :invalid)
      end
    end

    test "with `:host` option" do
      TestServer.UDP.start!()

      assert {"custom-host", _port} = TestServer.UDP.address(host: "custom-host")
    end

    test "with `:host` option when started with `ipfamily: :inet6` option" do
      TestServer.UDP.start!(ipfamily: :inet6)
      TestServer.UDP.handle()

      assert address = TestServer.UDP.address(host: "custom-host")
      assert {:ok, socket} = UDPClient.open(:inet6)
      assert UDPClient.send(socket, address, "ping", :inet6) == :ok

      assert {:ok, data} = UDPClient.receive_data(socket, :raw)
      assert {{0, 0, 0, 0, 0, 0, 0, 1}, _port, "ping"} = data
    end
  end

  describe "cacerts/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.UDP.Instance running", fn ->
        TestServer.UDP.cacerts()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.UDP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.UDP.start!(transport: :dtls)
                     :ok = TestServer.UDP.stop()

                     TestServer.UDP.cacerts(instance)
                   end
    end

    test "when not started with `transport: :dtls` option" do
      TestServer.UDP.start!()

      assert_raise RuntimeError,
                   ~r/is not running with `\[transport: :dtls\]` option/,
                   fn -> TestServer.UDP.cacerts() end
    end

    test "when started with `transport: :dtls` option with `:tls` option with custom certificates" do
      tls_options = [] |> TestServer.put_tls_options({:ec, :secp256r1}) |> Keyword.fetch!(:tls)

      TestServer.UDP.start!(transport: :dtls, tls: tls_options)

      assert_raise RuntimeError,
                   ~r/TestServer\.UDP\.Instance \#PID\<[0-9.]+\> is running with custom `:tls` certificate options/,
                   fn -> TestServer.UDP.cacerts() end
    end
  end

  describe "peer/1" do
    test "when instance not running" do
      instance = TestServer.UDP.start!()
      :ok = TestServer.UDP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.UDP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn -> TestServer.UDP.peer(instance) end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.UDP.start()
      {:ok, _instance_2} = TestServer.UDP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.UDP\.peer\/0`/,
                   fn -> TestServer.UDP.peer() end

      assert TestServer.UDP.peer(instance_1)

      :ok = TestServer.UDP.stop(instance_1)
    end

    test "when no data or socket received" do
      defmodule PeerNoDataReceivedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.peer()
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "has peers that were not used:"
    end

    test "when receiving an unexpected peer" do
      defmodule PeerNoPeersTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.start!(suppress_warning: true)

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), PeerNoPeersTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected UDP peer"
      assert io =~ "No peers registered."
      refute io =~ "The following peers were registered:"
      assert_receive {:data, data}
      assert data =~ "received an unexpected UDP peer"
    end

    test "when receiving unexpected peer after used peers" do
      defmodule PeersUnexpectedPeerAfterUsedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.start!(suppress_warning: true)
          TestServer.UDP.handle()

          assert {:ok, socket_1} = UDPClient.open()
          assert {:ok, socket_2} = UDPClient.open()

          assert UDPClient.send(socket_1, TestServer.UDP.address(), "ping") == :ok
          assert UDPClient.receive_data(socket_1) == {:ok, "ping"}
          assert UDPClient.send(socket_2, TestServer.UDP.address(), "ping") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket_2)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), PeersUnexpectedPeerAfterUsedTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected UDP peer"
      refute io =~ "No peers registered."
      assert io =~ "The following peers were registered:"
      assert_receive {:data, data}
      assert data =~ "received an unexpected UDP peer"
    end

    test "with multiple peers" do
      peer_1 = TestServer.UDP.peer()
      peer_2 = TestServer.UDP.peer()

      TestServer.UDP.handle(peer_1, to: fn _, state -> {:reply, "peer 1", state} end)
      TestServer.UDP.handle(peer_2, to: fn _, state -> {:reply, "peer 2", state} end)

      assert {:ok, socket_1} = UDPClient.open()
      assert {:ok, socket_2} = UDPClient.open()
      assert UDPClient.send(socket_2, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket_2) == {:ok, "peer 1"}
      assert UDPClient.send(socket_1, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket_1) == {:ok, "peer 2"}
    end

    test "when peer process dies" do
      defmodule HandleToFunctionRaisePeerRecoverTest do
        use ExUnit.Case

        test "continues" do
          instance = TestServer.UDP.start!(suppress_warning: true)
          peer = TestServer.UDP.peer(instance)
          address = TestServer.UDP.address(instance)

          TestServer.UDP.handle(peer, to: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, address, "first") == :ok
          assert {:ok, error} = UDPClient.receive_data(socket)
          assert error =~ "(RuntimeError) boom"
          assert [%{owner: owner}] = TestServer.UDP.Instance.peers(instance)
          assert monitor = Process.monitor(owner)
          assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}
          assert UDPClient.send(socket, address, "second") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToFunctionRaisePeerRecoverTest)

      assert io = capture_io(fn -> ExUnit.run() end)

      assert io =~
               "(RuntimeError) Could not handle UDP data, because: Peer process no longer accepts data."

      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end
  end

  describe "handle/2" do
    test "with multiple instances" do
      TestServer.UDP.start!()
      TestServer.UDP.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.UDP\.handle\/1`/,
                   fn -> TestServer.UDP.handle() end
    end

    test "with multiple peers" do
      TestServer.UDP.peer()
      TestServer.UDP.peer()

      assert_raise RuntimeError,
                   "Multiple peers available, please pass peer to `TestServer.UDP.handle/2`",
                   fn -> TestServer.UDP.handle() end

      TestServer.UDP.stop()
    end

    test "when peer instance not running" do
      instance = TestServer.UDP.start!()
      peer = TestServer.UDP.peer(instance)
      :ok = TestServer.UDP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.UDP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn -> TestServer.UDP.handle(peer) end
    end

    test "with invalid options" do
      peer = TestServer.UDP.peer()

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.UDP.handle(peer, invalid: :option)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.UDP.handle(peer, to: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.UDP.handle(peer, match: :invalid)
      end

      TestServer.UDP.stop()
    end

    test "when no data received" do
      defmodule HandleNoDataTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.handle()
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "did not receive data for these handlers before the test ended"
    end

    test "when receiving unexpected data" do
      defmodule HandleUnexpectedDataTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.start!(suppress_warning: true)
          TestServer.UDP.peer()

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleUnexpectedDataTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected UDP data"
      assert io =~ "No active handlers."
      refute io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end

    test "when receiving unexpected data before all handlers are processed" do
      defmodule HandleUnexpectedDataBeforeProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.start!(suppress_warning: true)
          TestServer.UDP.handle(match: fn _data, _state -> false end)

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
          :ok = TestServer.UDP.stop()
        end
      end

      Process.register(self(), HandleUnexpectedDataBeforeProcessedTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected UDP data"
      assert io =~ "Active handlers:"
      refute io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end

    test "when receiving unexpected data after all handlers are processed" do
      defmodule HandleUnexpectedDataAfterProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.start!(suppress_warning: true)
          TestServer.UDP.handle()

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, TestServer.UDP.address(), "first") == :ok
          assert UDPClient.receive_data(socket) == {:ok, "first"}
          assert UDPClient.send(socket, TestServer.UDP.address(), "second") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleUnexpectedDataAfterProcessedTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected UDP data"
      assert io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end

    test "with no existing peer" do
      TestServer.UDP.handle()

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket) == {:ok, "ping"}
    end

    test "with existing peer" do
      TestServer.UDP.peer()
      TestServer.UDP.handle()

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket) == {:ok, "ping"}
    end

    # It's not possible to test actual SSL errors in a controlled manner so
    # we simulate it by sending a :ssl_error message to the owner process
    test "when receiving :ssl_error" do
      defmodule HandleSSLErrorTest do
        use ExUnit.Case

        test "fails" do
          instance = TestServer.UDP.start!(transport: :dtls, suppress_warning: true)
          _peer = TestServer.UDP.peer()

          assert {:ok, socket} =
                   DTLSClient.connect(TestServer.UDP.address(), unquote(__MODULE__).tls_options())

          assert [%{owner: owner, socket: {:dtls, raw_socket}}] =
                   TestServer.UDP.Instance.peers(instance)

          send(owner, {:ssl_error, raw_socket, :test})
          assert {:ok, data} = DTLSClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleSSLErrorTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "UDP receive failed, because: :test"
      assert_receive {:data, data}
      assert data =~ "UDP receive failed, because: :test"
    end

    test "when `:to` function raises exception" do
      defmodule HandleToFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.start!(suppress_warning: true)
          TestServer.UDP.handle(to: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)
          assert UDPClient.receive_data(socket, 10) == {:error, :timeout}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.UDPTest.HandleToFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end

    test "when `:to` function returns an invalid response" do
      defmodule HandleToInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.start!(suppress_warning: true)
          TestServer.UDP.handle(to: fn _data, _state -> :invalid end)

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleToInvalidResponseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end

    test "with `:to` function returning `{:reply, data, state}` with invalid data" do
      defmodule HandleToReplyResponseInvalidDataTest do
        use ExUnit.Case

        test "fails" do
          LogHandler.setup()
          TestServer.UDP.start!(suppress_warning: true)
          TestServer.UDP.handle(to: fn _data, state -> {:reply, :not_iodata, state} end)

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)

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

      assert io =~ "UDP reply failed, because:"
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
      assert_received {:log, log}
      assert log =~ "Bad value on output port 'udp_inet'"
    end

    test "with `:to` function returning `{:reply, data, state}`" do
      TestServer.UDP.handle(to: fn _data, state -> {:reply, ["PO", [?N], "G"], state} end)

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket) == {:ok, "PONG"}
    end

    test "with `:to` function returning `{:ok, state}`" do
      TestServer.UDP.handle(to: fn _data, state -> {:ok, Map.put(state, :a, 1)} end)
      TestServer.UDP.handle(to: fn _data, state -> {:reply, inspect(state), state} end)

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket) == {:ok, inspect(%{a: 1})}
    end

    test "when `:match` function raises exception" do
      defmodule HandleMatchFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.UDP.start!(suppress_warning: true)
          TestServer.UDP.handle(match: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = UDPClient.open()
          assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
          assert {:ok, data} = UDPClient.receive_data(socket)
          assert UDPClient.receive_data(socket, 10) == {:error, :timeout}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleMatchFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.UDPTest.HandleMatchFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end

    test "with `:match` function" do
      TestServer.UDP.handle(
        match: fn data, _state -> data == "pong" end,
        to: fn _data, state -> {:reply, "1", state} end
      )

      TestServer.UDP.handle(to: fn _, state -> {:reply, "2", state} end)

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket) == {:ok, "2"}
      assert UDPClient.send(socket, TestServer.UDP.address(), "pong") == :ok
      assert UDPClient.receive_data(socket) == {:ok, "1"}
    end
  end

  describe "send/2" do
    test "when peer instance not running" do
      peer = TestServer.UDP.peer()
      :ok = TestServer.UDP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.UDP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn -> TestServer.UDP.send(peer) end
    end

    test "with invalid options" do
      peer = TestServer.UDP.peer()

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.UDP.send(peer, invalid: :option)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.UDP.send(peer, to: :invalid)
      end

      assert_raise ArgumentError, ~r/expected positive integer, got: :invalid/, fn ->
        TestServer.UDP.send(peer, timeout: :invalid)
      end

      assert_raise ArgumentError, ~r/expected positive integer, got: 0/, fn ->
        TestServer.UDP.send(peer, timeout: 0)
      end

      assert_raise ArgumentError, ~r/expected positive integer, got: -1/, fn ->
        TestServer.UDP.send(peer, timeout: -1)
      end

      TestServer.UDP.stop()
    end

    test "when peer doesn't exist" do
      instance = TestServer.UDP.start!()

      assert_raise RuntimeError,
                   ~r/cannot send to the peer, because the peer does not exist/,
                   fn -> TestServer.UDP.send({instance, make_ref()}) end
    end

    test "when client has not sent a datagram" do
      peer = TestServer.UDP.peer()

      assert_raise RuntimeError,
                   ~r/cannot send to the peer, because no client has sent a datagram or established a DTLS connection/,
                   fn -> TestServer.UDP.send(peer, timeout: 1) end

      TestServer.UDP.stop()
    end

    test "when started with `transport: :dtls` when client has disconnected" do
      instance = TestServer.UDP.start!(transport: :dtls)
      peer = TestServer.UDP.peer()

      assert {:ok, socket} = DTLSClient.connect(TestServer.UDP.address(), tls_options())
      assert [%{owner: owner}] = TestServer.UDP.Instance.peers(instance)
      monitor = Process.monitor(owner)
      assert DTLSClient.close(socket) == :ok
      assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}

      assert_raise RuntimeError,
                   ~r/cannot send to the peer, because client has disconnected/,
                   fn -> TestServer.UDP.send(peer) end
    end

    test "when peer is not yet known" do
      instance = TestServer.UDP.start!()
      peer = TestServer.UDP.peer(instance)
      :ok = TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)

      send_task =
        Task.async(fn ->
          TestServer.UDP.send(peer, to: fn state -> {:reply, "pong", state} end)
        end)

      wait_until(fn ->
        [%{subscribers: subscribers}] = TestServer.UDP.Instance.peers(instance)

        length(subscribers) == 1
      end)

      refute Task.yield(send_task, 0)
      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert Task.await(send_task) == :ok
      assert UDPClient.receive_data(socket) == {:ok, "pong"}
    end

    test "when timeout received after peer is known" do
      instance = TestServer.UDP.start!()
      peer = TestServer.UDP.peer(instance)
      :ok = TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)
      {:ok, socket} = UDPClient.open()
      :ok = UDPClient.send(socket, TestServer.UDP.address(instance), "connect")

      assert TestServer.UDP.send(peer, to: fn state -> {:ok, state} end) == :ok

      tag = make_ref()
      from = {self(), tag}

      send(instance, {:timeout, from, {:send, 0}})

      assert [_peer] = TestServer.UDP.Instance.peers(instance)
      refute_received {^tag, {:error, :enotconn}}
    end

    test "sends" do
      peer = TestServer.UDP.peer()
      TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)
      {:ok, socket} = UDPClient.open()
      :ok = UDPClient.send(socket, TestServer.UDP.address(), "connect")

      TestServer.UDP.send(peer)

      assert UDPClient.receive_data(socket) == {:ok, "ping"}
    end

    test "when `:to` function raises exception" do
      defmodule SendToFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          _instance = TestServer.UDP.start!(suppress_warning: true)
          peer = TestServer.UDP.peer()
          :ok = TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)
          {:ok, socket} = UDPClient.open()
          :ok = UDPClient.send(socket, TestServer.UDP.address(), "connect")

          TestServer.UDP.send(peer, to: fn _state -> raise "boom" end)

          assert {:ok, data} = UDPClient.receive_data(socket)
          assert UDPClient.receive_data(socket, 10) == {:error, :timeout}

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), SendToFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.UDPTest.SendToFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end

    test "when `:to` function returns an invalid response" do
      defmodule SendToInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          _instance = TestServer.UDP.start!(suppress_warning: true)
          peer = TestServer.UDP.peer()
          :ok = TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)
          {:ok, socket} = UDPClient.open()
          :ok = UDPClient.send(socket, TestServer.UDP.address(), "connect")

          TestServer.UDP.send(peer, to: fn _state -> :invalid end)

          assert {:ok, data} = UDPClient.receive_data(socket)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), SendToInvalidResponseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
    end

    test "when `:to` function returns `{:reply, data, state}` with invalid data" do
      defmodule SendToReplyResponseInvalidDataTest do
        use ExUnit.Case

        test "fails" do
          :ok = LogHandler.setup()
          _instance = TestServer.UDP.start!(suppress_warning: true)
          peer = TestServer.UDP.peer()
          :ok = TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)
          {:ok, socket} = UDPClient.open()
          :ok = UDPClient.send(socket, TestServer.UDP.address(), "connect")

          TestServer.UDP.send(peer, to: fn state -> {:reply, :not_iodata, state} end)

          assert {:ok, data} = UDPClient.receive_data(socket)
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

      assert io =~ "UDP reply failed, because:"
      assert_receive {:data, data}
      assert_io_udp_data(io, data)
      assert_received {:log, log}
      assert log =~ "Bad value on output port 'udp_inet'"
    end

    test "when `:to` function returns `{:reply, data, state}`" do
      peer = TestServer.UDP.peer()
      :ok = TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)
      {:ok, socket} = UDPClient.open()
      :ok = UDPClient.send(socket, TestServer.UDP.address(), "connect")

      TestServer.UDP.send(peer, to: fn state -> {:reply, ["PO", [?N], "G"], state} end)

      assert UDPClient.receive_data(socket) == {:ok, "PONG"}
    end

    test "when `:to` function returns `{:ok, state}`" do
      peer = TestServer.UDP.peer()
      :ok = TestServer.UDP.handle(peer, to: fn _data, state -> {:ok, state} end)
      {:ok, socket} = UDPClient.open()
      :ok = UDPClient.send(socket, TestServer.UDP.address(), "connect")

      TestServer.UDP.send(peer, to: fn state -> {:ok, Map.put(state, :a, 1)} end)
      TestServer.UDP.send(peer, to: fn state -> {:reply, inspect(state), state} end)

      assert UDPClient.receive_data(socket) == {:ok, inspect(%{a: 1})}
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

  def tls_options, do: tls_options(TestServer.UDP.cacerts())

  def tls_options(cacerts) do
    {host, _port} = TestServer.UDP.address()

    [
      protocol: :dtls,
      verify: :verify_peer,
      cacerts: cacerts,
      server_name_indication: String.to_charlist(host),
      log_level: :warning
    ]
  end

  defmodule UDPClient do
    def open(ipfamily \\ :inet) do
      :gen_udp.open(0, [ipfamily, :binary, active: false])
    end

    def send(socket, {host, port}, data, ipfamily \\ :inet) do
      {:ok, address} = :inet.getaddr(String.to_charlist(host), ipfamily)

      :gen_udp.send(socket, address, port, data)
    end

    def receive_data(socket), do: receive_data(socket, :normal)

    def receive_data(socket, timeout) when is_integer(timeout),
      do: receive_data(socket, :normal, timeout)

    def receive_data(socket, type) when is_atom(type), do: receive_data(socket, type, 1_000)

    def receive_data(socket, type, timeout) do
      case :gen_udp.recv(socket, 0, timeout) do
        {:ok, {_address, _port, data}} when type == :normal -> {:ok, data}
        {:ok, data} when type == :raw -> {:ok, data}
        {:error, error} -> {:error, error}
      end
    end
  end

  defmodule DTLSClient do
    def connect({host, port}, options \\ [], timeout \\ 1_000) do
      :ssl.connect(
        String.to_charlist(host),
        port,
        [protocol: :dtls, mode: :binary, active: false] ++ options,
        timeout
      )
    end

    def send(socket, data) do
      :ssl.send(socket, data)
    end

    def receive_data(socket, timeout \\ 1_000) do
      :ssl.recv(socket, 0, timeout)
    end

    def close(socket) do
      :ssl.close(socket)
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

  defp assert_io_udp_data(io, message) do
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
