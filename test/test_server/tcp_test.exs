defmodule TestServer.TCPTest do
  use ExUnit.Case
  doctest TestServer.TCP

  import ExUnit.CaptureIO

  describe "start/1" do
    test "with invalid port" do
      assert_raise RuntimeError, ~r/Invalid port, got: :invalid/, fn ->
        TestServer.TCP.start(port: :invalid)
      end

      assert_raise RuntimeError, ~r/Invalid port, got: 65536/, fn ->
        TestServer.TCP.start(port: 65_536)
      end

      assert_raise RuntimeError, ~r/Could not listen to port 4545, because: :eaddrinuse/, fn ->
        TestServer.TCP.start(port: 4545)
        TestServer.TCP.start(port: 4545)
      end
    end

    test "starts with multiple ports" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, instance_2} = TestServer.TCP.start()

      refute instance_1 == instance_2

      {_, port_1} = TestServer.TCP.address(instance_1)
      {_, port_2} = TestServer.TCP.address(instance_2)

      refute port_1 == port_2
    end

    test "starts in IPv6-only mode" do
      {:ok, _instance} = TestServer.TCP.start(ipfamily: :inet6)

      assert {:ok, socket} = tcp_connect([:inet6])
      assert {:ok, {ip, _port}} = :inet.sockname(socket)
      assert tuple_size(ip) == 8
    end

    test "with packet listen option" do
      {:ok, _instance} = TestServer.TCP.start(listen_options: [:binary, packet: :line])
      :ok = TestServer.TCP.handle()

      assert {:ok, socket} = tcp_connect(packet: :line)
      assert :ok = :gen_tcp.send(socket, "ping\n")
      assert {:ok, "ping\n"} = :gen_tcp.recv(socket, 0)
    end
  end

  describe "stop/1" do
    test "when not running" do
      assert_raise RuntimeError, "No current TestServer.TCP.Instance running", fn ->
        TestServer.TCP.stop()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     {:ok, instance} = TestServer.TCP.start()

                     assert :ok = TestServer.TCP.stop()

                     TestServer.TCP.stop(instance)
                   end
    end

    test "stops" do
      assert {:ok, pid} = TestServer.TCP.start()
      {host, port} = TestServer.TCP.address()

      assert :ok = TestServer.TCP.stop()
      refute Process.alive?(pid)

      assert {:error, :econnrefused} =
               :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
    end

    test "closes open client connections" do
      :ok = TestServer.TCP.handle()
      {host, port} = TestServer.TCP.address()

      {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "ping")
      assert {:ok, "ping"} = :gen_tcp.recv(socket, 0)

      assert :ok = TestServer.TCP.stop()
      assert {:error, :closed} = :gen_tcp.recv(socket, 0)
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, _instance_2} = TestServer.TCP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.stop\/0`/,
                   fn ->
                     TestServer.TCP.stop()
                   end

      assert :ok = TestServer.TCP.stop(instance_1)
      assert :ok = TestServer.TCP.stop()
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
                     {:ok, instance} = TestServer.TCP.start()

                     assert :ok = TestServer.TCP.stop()

                     TestServer.TCP.address(instance)
                   end
    end

    test "with invalid `:host`" do
      TestServer.TCP.start()

      assert_raise RuntimeError, ~r/Invalid host, got: :invalid/, fn ->
        TestServer.TCP.address(host: :invalid)
      end
    end

    test "produces address" do
      TestServer.TCP.start()

      assert {"localhost", port} = TestServer.TCP.address()
      assert is_integer(port)
    end

    test "with `:host`" do
      TestServer.TCP.start()

      assert {"custom-host", _port} = TestServer.TCP.address(host: "custom-host")
    end

    test "with `:host` in IPv6-only mode" do
      {:ok, _instance} = TestServer.TCP.start(ipfamily: :inet6)

      assert {:ok, _socket} = tcp_connect([:inet6])
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, instance_2} = TestServer.TCP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.address\/1`/,
                   fn ->
                     TestServer.TCP.address()
                   end

      refute TestServer.TCP.address(instance_1) == TestServer.TCP.address(instance_2)
    end
  end

  describe "handle/2" do
    test "when instance not running" do
      {:ok, instance} = TestServer.TCP.start()
      :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     TestServer.TCP.handle(instance)
                   end
    end

    test "with invalid options" do
      {:ok, _instance} = TestServer.TCP.start()

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.handle(to: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.handle(match: :invalid)
      end

      TestServer.TCP.stop()
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, _instance_2} = TestServer.TCP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.handle\/1`/,
                   fn ->
                     TestServer.TCP.handle()
                   end

      assert :ok = TestServer.TCP.handle(instance_1, to: fn _data, state -> {:ok, state} end)

      TestServer.TCP.stop(instance_1)
    end

    test "with no data received" do
      defmodule NoDataReceivedTest do
        use ExUnit.Case

        test "fails" do
          :ok = TestServer.TCP.handle()

          assert {:ok, _socket} = unquote(__MODULE__).tcp_connect()
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "did not receive data for these handlers before the test ended"
    end

    test "with default `:to` function" do
      :ok = TestServer.TCP.handle()

      assert {:ok, socket} = tcp_connect()
      assert :ok = :gen_tcp.send(socket, "ping")
      assert {:ok, "ping"} = :gen_tcp.recv(socket, 0)
    end

    test "with `:match` function filtering multiple handlers" do
      :ok =
        TestServer.TCP.handle(
          match: fn data, _state -> data == "first" end,
          to: fn _data, state -> {:reply, "pong", state} end
        )

      :ok =
        TestServer.TCP.handle(match: fn data, _state -> data == "second" end)

      assert {:ok, socket} = tcp_connect()
      assert :ok = :gen_tcp.send(socket, "second")
      assert {:ok, "second"} = :gen_tcp.recv(socket, 0)
      assert :ok = :gen_tcp.send(socket, "first")
      assert {:ok, "pong"} = :gen_tcp.recv(socket, 0)
    end

    test "with connection state threaded through handlers" do
      {:ok, _instance} = TestServer.TCP.start()

      :ok =
        TestServer.TCP.handle(
          to: fn _data, state ->
            count = Map.get(state, :count, 0) + 1

            {:reply, Integer.to_string(count), Map.put(state, :count, count)}
          end
        )

      :ok =
        TestServer.TCP.handle(
          to: fn _data, state ->
            count = Map.get(state, :count, 0) + 1

            {:reply, Integer.to_string(count), Map.put(state, :count, count)}
          end
        )

      assert {:ok, socket} = tcp_connect()
      assert :ok = :gen_tcp.send(socket, "next")
      assert {:ok, "1"} = :gen_tcp.recv(socket, 0)
      assert :ok = :gen_tcp.send(socket, "next")
      assert {:ok, "2"} = :gen_tcp.recv(socket, 0)
    end

    test "with `:to` function returning `{:ok, state}` response" do
      :ok =
        TestServer.TCP.handle(to: fn _data, state -> {:ok, state} end)

      assert {:ok, socket} = tcp_connect()
      assert :ok = :gen_tcp.send(socket, "ping")
      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
    end

    test "when receiving unexpected data" do
      defmodule UnexpectedDataTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.TCP.start(suppress_warning: true)

          assert {:ok, socket} = unquote(__MODULE__).tcp_connect()
          assert :ok = :gen_tcp.send(socket, "ping")
          assert {:ok, data} = :gen_tcp.recv(socket, 0)
          assert data =~ "received unexpected TCP data"
          assert data =~ "No active handlers"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected TCP data"
    end

    test "when receiving unexpected data after processed handlers" do
      defmodule UnexpectedDataAfterProcessedTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.TCP.start(suppress_warning: true)
          :ok = TestServer.TCP.handle()

          assert {:ok, socket} = unquote(__MODULE__).tcp_connect()
          assert :ok = :gen_tcp.send(socket, "first")
          assert {:ok, "first"} = :gen_tcp.recv(socket, 0)
          assert :ok = :gen_tcp.send(socket, "second")
          assert {:ok, data} = :gen_tcp.recv(socket, 0)
          assert data =~ "received unexpected TCP data"
          assert data =~ "The following handlers have been processed:"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected TCP data"
      assert io =~ "The following handlers have been processed:"
    end

    test "with `:to` 2-arity function raising exception" do
      defmodule HandleTo2ArityFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.TCP.start(suppress_warning: true)
          :ok = TestServer.TCP.handle(to: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = unquote(__MODULE__).tcp_connect()
          assert :ok = :gen_tcp.send(socket, "ping")
          assert {:ok, data} = :gen_tcp.recv(socket, 0)
          assert data =~ "(RuntimeError) boom"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.TCPTest.HandleTo2ArityFunctionRaiseTest"
    end

    test "with `:to` 2-arity function with invalid response" do
      defmodule HandleTo2ArityFunctionInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.TCP.start(suppress_warning: true)
          :ok = TestServer.TCP.handle(to: fn _data, _state -> :invalid end)

          assert {:ok, socket} = unquote(__MODULE__).tcp_connect()
          assert :ok = :gen_tcp.send(socket, "ping")
          assert {:ok, data} = :gen_tcp.recv(socket, 0)
          assert data =~ "(RuntimeError) Invalid callback response, got: :invalid."
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
    end

    test "with `:to` function returning iodata reply data" do
      {:ok, _instance} = TestServer.TCP.start()
      :ok = TestServer.TCP.handle(to: fn _data, state -> {:reply, ["PO", [?N], "G"], state} end)

      assert {:ok, socket} = tcp_connect()
      assert :ok = :gen_tcp.send(socket, "ping")
      assert {:ok, "PONG"} = :gen_tcp.recv(socket, 0)
    end

    test "when `:match` function raises exception" do
      defmodule MatchFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.TCP.start(suppress_warning: true)

          :ok = TestServer.TCP.handle(match: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = unquote(__MODULE__).tcp_connect()
          assert :ok = :gen_tcp.send(socket, "ping")
          assert {:ok, data} = :gen_tcp.recv(socket, 0)
          assert data =~ "(RuntimeError) boom"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.TCPTest.MatchFunctionRaiseTest"
    end
  end

  describe "connect/2" do
    test "when instance not running" do
      {:ok, instance} = TestServer.TCP.start()
      assert :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     TestServer.TCP.connect(instance, [])
                   end
    end

    test "autostarts an instance" do
      assert {:ok, {instance, ref}} = TestServer.TCP.connect()
      assert is_pid(instance)
      assert is_reference(ref)

      TestServer.TCP.stop(instance)
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, _instance_2} = TestServer.TCP.start()

      assert {:ok, {^instance_1, _ref}} = TestServer.TCP.connect(instance_1, [])

      TestServer.TCP.stop(instance_1)
    end

    test "returns distinct refs" do
      {:ok, instance} = TestServer.TCP.start()

      {:ok, {_, ref_1}} = TestServer.TCP.connect()
      {:ok, {_, ref_2}} = TestServer.TCP.connect()

      refute ref_1 == ref_2

      TestServer.TCP.stop(instance)
    end

    test "binds incoming sockets FIFO" do
      {:ok, instance} = TestServer.TCP.start()

      {:ok, conn_1} = TestServer.TCP.connect()
      {:ok, conn_2} = TestServer.TCP.connect()

      :ok = TestServer.TCP.handle(conn_1, to: fn _data, s -> {:reply, "one", s} end)
      :ok = TestServer.TCP.handle(conn_2, to: fn _data, s -> {:reply, "two", s} end)

      assert {:ok, socket_1} = tcp_connect()
      wait_for_connections(instance, 1)
      assert {:ok, socket_2} = tcp_connect()
      wait_for_connections(instance, 2)

      assert :ok = :gen_tcp.send(socket_1, "ping")
      assert {:ok, "one"} = :gen_tcp.recv(socket_1, 0)

      assert :ok = :gen_tcp.send(socket_2, "ping")
      assert {:ok, "two"} = :gen_tcp.recv(socket_2, 0)
    end

    test "scoped handler does not match data on other connections" do
      {:ok, instance} = TestServer.TCP.start()

      {:ok, conn_1} = TestServer.TCP.connect()

      :ok = TestServer.TCP.handle(conn_1, to: fn _data, s -> {:reply, "scoped", s} end)
      :ok = TestServer.TCP.handle(to: fn _data, s -> {:reply, "global", s} end)

      assert {:ok, socket_1} = tcp_connect()
      wait_for_connections(instance, 1)
      assert {:ok, socket_2} = tcp_connect()
      wait_for_connections(instance, 2)

      assert :ok = :gen_tcp.send(socket_2, "ping")
      assert {:ok, "global"} = :gen_tcp.recv(socket_2, 0)

      assert :ok = :gen_tcp.send(socket_1, "ping")
      assert {:ok, "scoped"} = :gen_tcp.recv(socket_1, 0)
    end

    test "anonymous connection still matches global handlers" do
      {:ok, _instance} = TestServer.TCP.start()

      :ok = TestServer.TCP.handle(to: fn data, s -> {:reply, data, s} end)

      assert {:ok, socket} = tcp_connect()
      assert :ok = :gen_tcp.send(socket, "ping")
      assert {:ok, "ping"} = :gen_tcp.recv(socket, 0)
    end

    test "with no socket received" do
      defmodule NoSocketReceivedTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _conn} = TestServer.TCP.connect()
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "has connections that were not used"
    end
  end

  describe "send/2" do
    test "when instance not running" do
      {:ok, conn} = TestServer.TCP.connect()
      assert :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     TestServer.TCP.send(conn)
                   end
    end

    test "with no client connected yet" do
      {:ok, instance} = TestServer.TCP.start()
      {:ok, conn} = TestServer.TCP.connect()

      assert_raise RuntimeError,
                   ~r/no client has connected/,
                   fn ->
                     TestServer.TCP.send(conn)
                   end

      assert {:ok, _socket} = tcp_connect()
      wait_for_connections(instance, 1)
    end

    test "with default callback function" do
      {:ok, instance} = TestServer.TCP.start()
      {:ok, conn} = TestServer.TCP.connect()
      assert {:ok, socket} = tcp_connect()
      wait_for_connections(instance, 1)

      assert :ok = TestServer.TCP.send(conn)
      assert {:ok, "ping"} = :gen_tcp.recv(socket, 0)
    end

    test "with callback function" do
      {:ok, instance} = TestServer.TCP.start()
      {:ok, conn} = TestServer.TCP.connect()
      assert {:ok, socket} = tcp_connect()
      wait_for_connections(instance, 1)

      assert :ok =
               TestServer.TCP.send(conn,
                 to: fn state ->
                   {:reply, "pong", state}
                 end
               )

      assert {:ok, "pong"} = :gen_tcp.recv(socket, 0)
    end

    test "with callback function returning `{:ok, state}` response" do
      {:ok, instance} = TestServer.TCP.start()
      {:ok, conn} = TestServer.TCP.connect()
      assert {:ok, socket} = tcp_connect()
      wait_for_connections(instance, 1)

      assert :ok = TestServer.TCP.send(conn, to: fn state -> {:ok, state} end)
      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
    end

    test "targets only the given connection" do
      {:ok, instance} = TestServer.TCP.start()
      {:ok, conn_1} = TestServer.TCP.connect()
      {:ok, _conn_2} = TestServer.TCP.connect()

      assert {:ok, socket_1} = tcp_connect()
      wait_for_connections(instance, 1)
      assert {:ok, socket_2} = tcp_connect()
      wait_for_connections(instance, 2)

      assert :ok =
               TestServer.TCP.send(conn_1,
                 to: fn state ->
                   {:reply, "pong", state}
                 end
               )

      assert {:ok, "pong"} = :gen_tcp.recv(socket_1, 0)
      assert {:error, :timeout} = :gen_tcp.recv(socket_2, 0, 100)
    end

    test "with connection state threaded through sends and handlers" do
      {:ok, instance} = TestServer.TCP.start()
      {:ok, conn} = TestServer.TCP.connect()

      :ok =
        TestServer.TCP.handle(conn,
          to: fn _data, state ->
            count = Map.get(state, :count, 0) + 1

            {:reply, Integer.to_string(count), Map.put(state, :count, count)}
          end
        )

      assert {:ok, socket} = tcp_connect()
      wait_for_connections(instance, 1)
      assert :ok = :gen_tcp.send(socket, "next")
      assert {:ok, "1"} = :gen_tcp.recv(socket, 0)

      assert :ok =
               TestServer.TCP.send(conn,
                 to: fn state ->
                   count = Map.get(state, :count, 0) + 1

                   {:reply, Integer.to_string(count), Map.put(state, :count, count)}
                 end
               )

      assert {:ok, "2"} = :gen_tcp.recv(socket, 0)
    end

    test "with invalid options" do
      {:ok, instance} = TestServer.TCP.start()
      {:ok, conn} = TestServer.TCP.connect()
      assert {:ok, _socket} = tcp_connect()
      wait_for_connections(instance, 1)

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.send(conn, to: :invalid)
      end
    end

    test "with invalid callback response" do
      defmodule SendInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} = TestServer.TCP.start(suppress_warning: true)
          {:ok, conn} = TestServer.TCP.connect()
          assert {:ok, socket} = unquote(__MODULE__).tcp_connect()
          unquote(__MODULE__).wait_for_connections(instance, 1)

          assert :ok = TestServer.TCP.send(conn, to: fn _state -> :invalid end)
          assert {:ok, data} = :gen_tcp.recv(socket, 0)
          assert data =~ "(RuntimeError) Invalid callback response, got: :invalid."
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "(RuntimeError) Invalid callback response, got: :invalid."
    end

    test "with callback function raising exception" do
      defmodule SendFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} = TestServer.TCP.start(suppress_warning: true)
          {:ok, conn} = TestServer.TCP.connect()
          assert {:ok, socket} = unquote(__MODULE__).tcp_connect()
          unquote(__MODULE__).wait_for_connections(instance, 1)

          assert :ok = TestServer.TCP.send(conn, to: fn _state -> raise "boom" end)
          assert {:ok, data} = :gen_tcp.recv(socket, 0)
          assert data =~ "(RuntimeError) boom"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.TCPTest.SendFunctionRaiseTest"
    end
  end

  def tcp_connect(options \\ []) do
    {host, port} = TestServer.TCP.address()

    :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false] ++ options)
  end

  def wait_for_connections(instance, count, attempts \\ 50)

  def wait_for_connections(instance, count, attempts) when attempts > 0 do
    case bound_connections(instance) do
      connections when length(connections) == count ->
        :ok

      _connections ->
        Process.sleep(10)
        wait_for_connections(instance, count, attempts - 1)
    end
  end

  def wait_for_connections(instance, count, 0) do
    connections = bound_connections(instance)

    flunk("expected #{count} TCP connections, got #{length(connections)}")
  end

  defp bound_connections(instance) do
    instance
    |> TestServer.TCP.Instance.connections()
    |> Enum.filter(&(not is_nil(&1.pid)))
  end
end
