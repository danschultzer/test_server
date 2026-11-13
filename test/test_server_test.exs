defmodule TestServerTest do
  use ExUnit.Case
  doctest TestServer

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  defmodule FakeProtocol do
    defmodule Instance do
      use GenServer

      def start_link(options), do: GenServer.start_link(__MODULE__, options)

      @impl true
      def init(options), do: Keyword.get(options, :init, fn -> {:ok, %{}} end).()

      @impl true
      def handle_info(:crash, _state), do: raise("boom")

      def handle_info({:stop, reason}, state), do: {:stop, reason, state}
    end

    def stop(instance), do: TestServer.stop_instance(__MODULE__, instance)
  end

  describe "start_instance/3" do
    test "when not called from a test process" do
      assert %ArgumentError{
               message:
                 "cannot start a TestServerTest.FakeProtocol instance outside the test process"
             } =
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

    test "when verify_instance_fn raises exception" do
      Process.register(self(), __MODULE__)

      defmodule StartInstanceVerifyInstanceFnFailsTest do
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

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert_received {:instance, instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance)
    end

    test "when instance crashes" do
      Process.register(self(), __MODULE__)

      defmodule StartInstanceInstanceCrashTest do
        use ExUnit.Case

        test "fails" do
          options = [
            init: fn ->
              Process.send_after(self(), :crash, 10)

              {:ok, %{}}
            end
          ]

          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              options,
              fn _instance -> :ok end
            )

          send(unquote(__MODULE__), {:instance, instance})

          Process.sleep(10_000)
          flunk("Instance did not crash as expected")
        end
      end

      assert io =
               capture_io(fn ->
                 log =
                   capture_log(fn ->
                     assert %{failures: 1} = ExUnit.run()
                   end)

                 assert log =~ "terminating"
                 assert log =~ "(RuntimeError) boom"
               end)

      assert io =~ "an exception was raised:"
      assert io =~ "(RuntimeError) boom"
      assert_received {:instance, instance}
      assert %{active: 0} = DynamicSupervisor.count_children(TestServer.InstanceSupervisor)
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance)
    end

    test "when instance crashes after test ended" do
      Process.register(self(), __MODULE__)

      defmodule StartInstanceInstanceCrashAfterTestEndTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> :ok end
            )

          send(unquote(__MODULE__), {:instance, instance})

          on_exit(fn ->
            ref = Process.monitor(instance)
            send(instance, :crash)

            assert_receive {:DOWN, ^ref, :process, ^instance, {%RuntimeError{}, _stacktrace}}
          end)
        end
      end

      assert io =
               capture_io(fn ->
                 log =
                   capture_log(fn ->
                     assert %{failures: 1} = ExUnit.run()
                   end)

                 assert log =~ "terminating"
                 assert log =~ "(RuntimeError) boom"
               end)

      assert io =~
               ~r/expected TestServerTest\.FakeProtocol\.Instance \#PID\<[0-9.]+\> to be running, but it exited with reason:/

      assert_received {:instance, instance}
      assert %{active: 0} = DynamicSupervisor.count_children(TestServer.InstanceSupervisor)
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      assert io =~ "(RuntimeError) boom"
      refute Process.alive?(instance)
    end

    test "when instance is stopped with `:normal`" do
      Process.register(self(), __MODULE__)

      defmodule StartInstanceInstanceNormalShutDownTest do
        use ExUnit.Case

        test "fails during on_exit" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> :ok end
            )

          ref = Process.monitor(instance)
          send(unquote(__MODULE__), {:instance, instance})
          send(instance, {:stop, :normal})

          assert_receive {:DOWN, ^ref, :process, ^instance, :normal}
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)

      assert io =~
               ~r/expected TestServerTest\.FakeProtocol\.Instance \#PID\<[0-9.]+\> to be running, but it exited with reason:/

      assert io =~ "normal"
      assert_received {:instance, instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance)
    end

    test "when instance is stopped with `{:shutdown, reason}`" do
      Process.register(self(), __MODULE__)

      defmodule StartInstanceInstanceShutdownShutDownTest do
        use ExUnit.Case

        test "fails during on_exit" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> :ok end
            )

          ref = Process.monitor(instance)
          send(unquote(__MODULE__), {:instance, instance})
          send(instance, {:stop, {:shutdown, :normal}})

          assert_receive {:DOWN, ^ref, :process, ^instance, {:shutdown, :normal}}
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)

      assert io =~
               ~r/expected TestServerTest\.FakeProtocol\.Instance \#PID\<[0-9.]+\> to be running, but it exited with reason:/

      assert io =~ "shutdown"
      assert_received {:instance, instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance)
    end
  end

  describe "stop_instance/2" do
    test "when instance doesn't exist" do
      assert_raise RuntimeError,
                   ~r/expected TestServerTest\.FakeProtocol\.Instance \#PID\<[0-9.]+\> to be an TestServer managed instance/,
                   fn ->
                     assert TestServer.stop_instance(unquote(__MODULE__).FakeProtocol, self()) ==
                              :ok
                   end
    end

    test "with stopped instance" do
      {:ok, instance} = TestServer.start_instance(FakeProtocol, [], fn _instance -> :ok end)
      :ok = TestServer.stop_instance(FakeProtocol, instance)

      exception =
        assert_raise RuntimeError, fn ->
          TestServer.stop_instance(FakeProtocol, instance)
        end

      assert exception.message =~
               ~r/expected TestServerTest\.FakeProtocol\.Instance \#PID\<[0-9.]+\> to be running, but it was stopped at:/

      assert exception.message =~ ~r/test\/test_server_test\.exs:\d+/

      assert exception.message =~
               "TestServerTest.\"test stop_instance/2 with stopped instance\"/1"
    end

    test "when test ends" do
      Process.register(self(), __MODULE__)

      defmodule StopInstanceTestEndsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn instance ->
                assert TestServer.InstanceManager.fetch_instance_entry(instance) ==
                         {:error, :not_found}
              end
            )

          assert TestServer.stop_instance(unquote(__MODULE__).FakeProtocol, instance) == :ok

          send(unquote(__MODULE__), {:instance, instance})
        end
      end

      capture_io(fn ->
        assert %{failures: 0} = ExUnit.run()
      end)

      assert_received {:instance, instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance)
    end
  end

  describe "validate_port!/1" do
    test "with invalid `:port` option" do
      assert_raise ArgumentError,
                   "expected :port to be an integer from 0 to 65535, got: :invalid",
                   fn ->
                     TestServer.validate_port!(port: :invalid)
                   end

      assert_raise ArgumentError,
                   "expected :port to be an integer from 0 to 65535, got: 65536",
                   fn ->
                     TestServer.validate_port!(port: 65_536)
                   end
    end

    test "with missing `:port` option" do
      assert TestServer.validate_port!([]) == 0
    end

    test "with `:port` option" do
      assert TestServer.validate_port!(port: 4040) == 4040
    end
  end

  describe "open_port/1" do
    test "when port in use" do
      assert {:ok, socket} = :gen_tcp.listen(0, [])
      assert {:ok, port} = :inet.port(socket)

      assert {:error, %RuntimeError{message: message}} = TestServer.open_port(port: port)
      assert message == "could not listen on port #{port}: :eaddrinuse"
    end

    test "with missing `:port` option" do
      assert {:ok, port} = TestServer.open_port([])
      assert is_integer(port)
      refute port_in_use?(port)
    end

    test "with `:port` option" do
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
