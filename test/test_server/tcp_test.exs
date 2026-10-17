defmodule TestServer.TCPTest do
  use ExUnit.Case
  doctest TestServer.TCP

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias __MODULE__.{LogHandler, TCPClient}

  describe "start/1" do
    test "with invalid port" do
      assert_raise ArgumentError, ~r/expected a port, got: :invalid/, fn ->
        TestServer.TCP.start(port: :invalid)
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
      TestServer.TCP.start!(ipfamily: :inet6)
      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address(), [:inet6])
      assert TCPClient.send(socket, "ping") == {:ok, "ping"}
      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, _port}} = :inet.peername(socket)
    end
  end

  describe "start!/1" do
    test "returns instance" do
      assert instance = TestServer.TCP.start!()
      assert is_pid(instance)
    end

    test "when start fails" do
      TestServer.TCP.start!(port: 2323)

      assert_raise RuntimeError,
                   ~r/EXIT when starting TestServer.TCP instance on port 2323/,
                   fn -> TestServer.TCP.start!(port: 2323) end
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
                     instance = TestServer.TCP.start!()
                     :ok = TestServer.TCP.stop()

                     TestServer.TCP.stop(instance)
                   end
    end

    test "stops" do
      instance = TestServer.TCP.start!()
      address = TestServer.TCP.address()

      assert {:ok, socket} = TCPClient.connect(address)
      assert TestServer.TCP.stop() == :ok
      refute Process.alive?(instance)
      assert {:error, :econnrefused} = TCPClient.connect(address)
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

      assert TestServer.TCP.stop(instance_1) == :ok
      assert TestServer.TCP.stop() == :ok
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

    test "with invalid `:host`" do
      TestServer.TCP.start!()

      assert_raise RuntimeError, ~r/Invalid host, got: :invalid/, fn ->
        TestServer.TCP.address(host: :invalid)
      end
    end

    test "produces address" do
      TestServer.TCP.start!()

      assert {"localhost", port} = TestServer.TCP.address()
      assert is_integer(port)
    end

    test "with `:host`" do
      TestServer.TCP.start!()

      assert {"custom-host", _port} = TestServer.TCP.address(host: "custom-host")
    end

    test "with `:host` in IPv6-only mode" do
      TestServer.TCP.start!(ipfamily: :inet6)
      TestServer.TCP.handle()

      assert {:ok, socket} =
               TCPClient.connect(TestServer.TCP.address(host: "custom-host"), [:inet6])

      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, _port}} = :inet.peername(socket)
      assert TCPClient.send(socket, "ping") == {:ok, "ping"}
    end

    test "with multiple instances" do
      instance_1 = TestServer.TCP.start!()
      instance_2 = TestServer.TCP.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.address\/1`/,
                   fn ->
                     TestServer.TCP.address()
                   end

      refute TestServer.TCP.address(instance_1) == TestServer.TCP.address(instance_2)
    end
  end

  describe "connection/1" do
    test "when instance not running" do
      instance = TestServer.TCP.start!()
      :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     TestServer.TCP.connection(instance)
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.TCP.start()
      {:ok, _instance_2} = TestServer.TCP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.connection\/0`/,
                   fn ->
                     TestServer.TCP.connection()
                   end

      assert TestServer.TCP.connection(instance_1)

      :ok = TestServer.TCP.stop(instance_1)
    end

    test "with no socket received" do
      defmodule ConnectionNoSocketReceivedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.connection()
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "has connections that were not used:"
    end

    test "when receiving an unexpected socket" do
      defmodule UnexpectedConnectionTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.receive_data(socket)
          assert data =~ "received an unexpected TCP connection attempt"
          assert data =~ "No available connections"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected TCP connection attempt"
      assert io =~ "No available connections"
      refute io =~ "The following connections have been used:"
    end

    test "when receiving unexpected socket after used connections" do
      defmodule ConnectionsTooManyConnectionsAfterUsedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle()

          assert {:ok, _socket_1} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, socket_2} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.receive_data(socket_2)
          assert data =~ "received an unexpected TCP connection attempt"
          assert data =~ "No available connections"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "No available connections"
      assert io =~ "The following connections have been used:"
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
      assert TCPClient.send(socket_2, "ping") == {:ok, "connection 2"}
      assert TCPClient.send(socket_1, "ping") == {:ok, "connection 1"}
    end
  end

  describe "handle/2" do
    test "with multiple instances" do
      TestServer.TCP.start!()
      TestServer.TCP.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.TCP\.handle\/1`/,
                   fn ->
                     TestServer.TCP.handle()
                   end
    end

    test "with multiple connections" do
      TestServer.TCP.connection()
      TestServer.TCP.connection()

      assert_raise RuntimeError,
                   ~r/Multiple connections available, please pass connection to `TestServer\.TCP\.handle\/2`/,
                   fn ->
                     TestServer.TCP.handle()
                   end

      TestServer.TCP.stop()
    end

    test "when connection instance not running" do
      connection = TestServer.TCP.connection()
      :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     TestServer.TCP.handle(connection)
                   end
    end

    test "with invalid options" do
      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.handle(to: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.handle(match: :invalid)
      end

      TestServer.TCP.stop()
    end

    test "with no data received" do
      defmodule HandleNoDataTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.handle()

          assert {:ok, _socket} = TCPClient.connect(TestServer.TCP.address())
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "did not receive data for these handlers before the test ended"
    end

    test "when receiving unexpected data" do
      defmodule HandleUnexpectedDataTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.connection()

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.send(socket, "ping")
          assert data =~ "received unexpected TCP data"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected TCP data"
      refute io =~ "The following handlers have been processed:"
    end

    test "when receiving unexpected data after processed handlers" do
      defmodule HandleUnexpectedDataAfterProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle()

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert TCPClient.send(socket, "first") == {:ok, "first"}
          assert {:ok, data} = TCPClient.send(socket, "second")
          assert data =~ "received unexpected TCP data"
          assert data =~ "The following handlers have been processed:"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received unexpected TCP data"
      assert io =~ "The following handlers have been processed:"
    end

    test "with no existing connection" do
      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == {:ok, "ping"}
    end

    test "with existing connection" do
      TestServer.TCP.connection()
      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == {:ok, "ping"}
    end

    test "when `:to` function raises exception" do
      defmodule HandleToFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(to: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.send(socket, "ping")
          assert data =~ "(RuntimeError) boom"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.TCPTest.HandleToFunctionRaiseTest"
    end

    test "when `:to` function returns an invalid response" do
      defmodule HandleToInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(to: fn _data, _state -> :invalid end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.send(socket, "ping")
          assert data =~ "(RuntimeError) Invalid callback response, got: :invalid."
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
    end

    test "with `:to` function returning `{:reply, data, state}` with invalid data" do
      defmodule HandleToReplyResponseInvalidDataTest do
        use ExUnit.Case

        test "fails" do
          LogHandler.setup()
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(to: fn _data, state -> {:reply, :not_iodata, state} end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.send(socket, "ping")
          assert data =~ "TCP reply failed, because:"

          assert_receive {:log, msg}
          assert msg =~ "Bad value on output port 'tcp_inet'"
        end
      end

      assert io =
               capture_io(fn ->
                 log = capture_log(fn -> ExUnit.run() end)

                 send(self(), {:log, log})
               end)

      assert_received {:log, log}

      assert io =~ "TCP reply failed, because:"
      assert log =~ "Bad value on output port 'tcp_inet'"
    end

    test "with `:to` function returning `{:reply, data, state}`" do
      TestServer.TCP.start!()
      TestServer.TCP.handle(to: fn _data, state -> {:reply, ["PO", [?N], "G"], state} end)

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == {:ok, "PONG"}
    end

    test "with `:to` function returning `{:ok, state}`" do
      TestServer.TCP.handle(to: fn _data, state -> {:ok, Map.put(state, :a, 1)} end)
      TestServer.TCP.handle(to: fn _data, state -> {:reply, inspect(state), state} end)

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send_async(socket, "ping")
      assert TCPClient.send(socket, "ping") == {:ok, inspect(%{a: 1})}
    end

    test "when `:match` function raises exception" do
      defmodule HandleMatchFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.TCP.start!(suppress_warning: true)
          TestServer.TCP.handle(match: fn _data, _state -> raise "boom" end)

          assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
          assert {:ok, data} = TCPClient.send(socket, "ping")
          assert data =~ "(RuntimeError) boom"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.TCPTest.HandleMatchFunctionRaiseTest"
    end

    test "with `:match` function" do
      TestServer.TCP.handle(
        match: fn data, _state -> data == "pong" end,
        to: fn _data, state -> {:reply, "ping", state} end
      )

      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == {:ok, "ping"}
      assert TCPClient.send(socket, "pong") == {:ok, "ping"}
    end
  end

  describe "send/2" do
    test "when connection instance not running" do
      {connection, _socket} = bounded_connection()
      :ok = TestServer.TCP.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.TCP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     TestServer.TCP.send(connection)
                   end
    end

    test "with invalid options" do
      {connection, _socket} = bounded_connection()

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.TCP.send(connection, to: :invalid)
      end
    end

    test "when client has not connected" do
      connection = TestServer.TCP.connection()

      assert_raise RuntimeError,
                   ~r/cannot send to the connection, because no client has connected to it/,
                   fn ->
                     TestServer.TCP.send(connection)
                   end

      TestServer.TCP.stop()
    end

    test "when connection doesn't exist" do
      instance = TestServer.TCP.start!()

      assert_raise RuntimeError,
                   ~r/cannot send to the connection, because the connection does not exist/,
                   fn ->
                     TestServer.TCP.send({instance, make_ref()})
                   end
    end

    test "when client has disconnected" do
      {connection, socket} = bounded_connection()

      assert TCPClient.close(socket) == :ok

      :timer.sleep(1)

      assert_raise RuntimeError,
                   ~r/cannot send to the connection, because client has disconnected/,
                   fn ->
                     TestServer.TCP.send(connection)
                   end
    end

    test "when `:to` function raises exception" do
      defmodule SendToFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.TCP.start(suppress_warning: true)
          {connection, socket} = unquote(__MODULE__).bounded_connection()

          TestServer.TCP.send(connection, to: fn _state -> raise "boom" end)

          assert {:ok, data} = TCPClient.receive_data(socket)
          assert data =~ "(RuntimeError) boom"
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.TCPTest.SendToFunctionRaiseTest"
    end

    test "when `:to` function returns an invalid response" do
      defmodule SendToInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.TCP.start(suppress_warning: true)
          {connection, socket} = unquote(__MODULE__).bounded_connection()

          TestServer.TCP.send(connection, to: fn _state -> :invalid end)

          assert {:ok, data} = TCPClient.receive_data(socket)
          assert data =~ "(RuntimeError) Invalid callback response, got: :invalid."
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
    end

    test "with `:to` function returning `{:reply, data, state}` with invalid data" do
      defmodule SendToReplyResponseInvalidDataTest do
        use ExUnit.Case

        test "fails" do
          LogHandler.setup()

          {:ok, _instance} = TestServer.TCP.start(suppress_warning: true)
          {connection, socket} = unquote(__MODULE__).bounded_connection()

          TestServer.TCP.send(connection, to: fn state -> {:reply, :not_iodata, state} end)

          assert {:ok, data} = TCPClient.receive_data(socket)
          assert data =~ "TCP reply failed, because:"

          assert_receive {:log, msg}
          assert msg =~ "Bad value on output port 'tcp_inet'"
        end
      end

      assert io =
               capture_io(fn ->
                 log = capture_log(fn -> ExUnit.run() end)

                 send(self(), {:log, log})
               end)

      assert_received {:log, log}

      assert io =~ "TCP reply failed, because:"
      assert log =~ "Bad value on output port 'tcp_inet'"
    end

    test "with `:to` function returning `{:reply, data, state}`" do
      {connection, socket} = bounded_connection()

      TestServer.TCP.send(connection, to: fn state -> {:reply, ["PO", [?N], "G"], state} end)

      assert TCPClient.receive_data(socket) == {:ok, "PONG"}
    end

    test "with `:to` function returning `{:ok, state}`" do
      {connection, socket} = bounded_connection()

      TestServer.TCP.send(connection, to: fn state -> {:ok, Map.put(state, :a, 1)} end)
      TestServer.TCP.send(connection, to: fn state -> {:reply, inspect(state), state} end)

      assert TCPClient.receive_data(socket) == {:ok, inspect(%{a: 1})}
    end

    test "when connection is not yet accepted" do
      instance = TestServer.TCP.start!()
      connection = TestServer.TCP.connection(instance)
      address = TestServer.TCP.address(instance)

      :sys.suspend(instance)

      send_task =
        Task.async(fn ->
          TestServer.TCP.send(connection, to: fn state -> {:reply, "pong", state} end)
        end)

      wait_until(fn -> Process.info(instance, :message_queue_len) == {:message_queue_len, 1} end)

      assert {:messages,
              [
                {:"$gen_call", _, {:dispatch, {:send, {^connection, _options, _stacktrace}}}}
              ]} = Process.info(instance, :messages)

      {:ok, socket} = TCPClient.connect(address)

      wait_until(fn -> Process.info(instance, :message_queue_len) == {:message_queue_len, 2} end)

      assert {:messages,
              [
                {:"$gen_call", _, {:dispatch, {:send, {^connection, _options, _stacktrace}}}},
                {:"$gen_call", _, {:dispatch, {:connection, {_owner, _socket}}}}
              ]} = Process.info(instance, :messages)

      refute Task.yield(send_task, 0)

      :sys.resume(instance)

      assert Task.await(send_task) == :ok
      assert TCPClient.receive_data(socket, 0) == {:ok, "pong"}
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

  def bounded_connection do
    connection = TestServer.TCP.connection()
    :ok = TestServer.TCP.handle()

    assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
    assert TCPClient.send(socket, "ping") == {:ok, "ping"}

    {connection, socket}
  end

  defmodule TCPClient do
    def connect({host, port}, options \\ []) do
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false] ++ options)
    end

    def send_async(socket, data) do
      :ok = :gen_tcp.send(socket, data)

      :timer.sleep(10)
    end

    def send(socket, data) do
      :ok = :gen_tcp.send(socket, data)

      receive_data(socket)
    end

    def receive_data(socket, length \\ 0) do
      :gen_tcp.recv(socket, length)
    end

    def close(socket) do
      :gen_tcp.close(socket)
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
end
