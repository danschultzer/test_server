defmodule TestServerTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  defmodule FakeProtocol do
    defmodule Instance do
      use GenServer

      def start_link(options), do: GenServer.start_link(__MODULE__, options)

      @impl true
      def init(options), do: Keyword.get(options, :init, fn -> {:ok, %{}} end).()
    end

    def stop(instance), do: TestServer.stop_instance(__MODULE__, instance)
  end

  describe "start_instance/3" do
    test "when not called from a test process" do
      assert %ArgumentError{message: "can only be called in a test process"} =
               Task.async(fn ->
                 try do
                   TestServer.start_instance(FakeProtocol, [], fn _instance -> :ok end)
                 rescue
                   error -> error
                 end
               end)
               |> Task.await()
    end

    test "when instance fails to start" do
      options = [init: fn -> {:stop, {:shutdown, :boom}} end]

      assert {:error, {:shutdown, :boom}} =
               TestServer.start_instance(FakeProtocol, options, fn _instance -> :ok end)
    end

    test "when instance raises on start" do
      options = [init: fn -> raise "boom" end]

      assert_raise RuntimeError, "boom", fn ->
        TestServer.start_instance(FakeProtocol, options, fn _instance -> :ok end)
      end
    end

    test "when verify_fn raises exception" do
      Process.register(self(), __MODULE__)

      defmodule VerificationFailsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> raise "boom" end
            )

          send(unquote(__MODULE__), {:instance, instance})
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "boom"
      assert_received {:instance, instance}
      refute Process.alive?(instance)
    end
  end

  describe "open_port/1" do
    test "with invalid port" do
      assert_raise ArgumentError, "expected a port, got: :invalid", fn ->
        TestServer.open_port(port: :invalid)
      end

      assert_raise ArgumentError, "expected a port, got: 65536", fn ->
        TestServer.open_port(port: 65_536)
      end
    end

    test "when port in use" do
      assert {:ok, socket} = :gen_tcp.listen(0, [])
      assert {:ok, port} = :inet.port(socket)

      assert {:error, %RuntimeError{message: message}} = TestServer.open_port(port: port)
      assert message == "Could not listen to port #{port}, because: :eaddrinuse"
    end

    test "without port option" do
      assert {:ok, port} = TestServer.open_port([])
      refute port_in_use?(port)
    end

    test "with port option" do
      assert {:ok, port} = TestServer.open_port(port: {0, ip: {127, 0, 0, 1}})
      refute port_in_use?(port)
    end
  end

  defp port_in_use?(port) do
    case :gen_tcp.listen(port, []) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)

        false

      {:error, _reason} ->
        true
    end
  end
end
