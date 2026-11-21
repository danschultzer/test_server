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

    def stop(instance) do
      result = TestServer.stop_instance(instance)

      Process.get({unquote(__MODULE__), :raise_on_stop}) && raise "boom"

      result
    end
  end

  describe "start_instance/3" do
    test "when not called from a test process" do
      assert %ArgumentError{
               message:
                 "cannot start a TestServerTest.FakeProtocol instance outside a test process"
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

    test "when instance crashes during test" do
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

          send(__MODULE__, {:instance, instance})
          send(__MODULE__, {:test_pid, self()})

          :timer.sleep(10_000)

          flunk("Instance did not crash as expected")
        end
      end

      Process.register(self(), StartInstanceInstanceCrashTest)

      assert {log, io} =
               with_io(fn ->
                 capture_log(fn -> assert %{failures: 1} = ExUnit.run() end)
               end)

      assert_received {:instance, {FakeProtocol, instance_pid} = instance}
      assert_received {:test_pid, test_pid}

      assert io =~
               "(EXIT from #{inspect(test_pid)}) an exception was raised:\n         ** (RuntimeError) boom"

      assert log =~ "GenServer #{inspect(instance_pid)} terminating\n** (RuntimeError) boom"
      assert %{active: 0} = DynamicSupervisor.count_children(TestServer.InstanceSupervisor)
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance_pid)
    end

    test "when test ends when instance crashes" do
      defmodule StartInstanceTestEndInstanceCrashTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> :ok end
            )

          send(__MODULE__, {:instance, instance})

          on_exit(fn ->
            {FakeProtocol, instance_pid} = instance
            monitor = Process.monitor(instance_pid)

            send(instance_pid, :crash)

            assert_receive {:DOWN, ^monitor, :process, ^instance_pid,
                            {%RuntimeError{}, _stacktrace}}
          end)
        end
      end

      Process.register(self(), StartInstanceTestEndInstanceCrashTest)

      assert {log, io} =
               with_io(fn ->
                 capture_log(fn -> assert %{failures: 1} = ExUnit.run() end)
               end)

      assert_received {:instance, {FakeProtocol, instance_pid} = instance}
      assert log =~ "GenServer #{inspect(instance_pid)} terminating\n** (RuntimeError) boom"

      assert io =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be running, but it exited with reason:\n"

      assert io =~ "     an exception was raised:\n         ** (RuntimeError) boom"
      assert %{active: 0} = DynamicSupervisor.count_children(TestServer.InstanceSupervisor)
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance_pid)
    end

    test "when test ends when instance stopped" do
      defmodule StartInstanceTestEndInstanceStoppedTest do
        use ExUnit.Case

        test "succeeds" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> :ok end
            )

          TestServer.stop_instance(instance)

          send(__MODULE__, {:instance, instance})
        end
      end

      Process.register(self(), StartInstanceTestEndInstanceStoppedTest)

      assert capture_io(fn -> assert %{failures: 0} = ExUnit.run() end)
      assert_received {:instance, instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
    end

    test "when test ends when instance exited" do
      defmodule StartInstanceTestEndInstanceExitedTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> :ok end
            )

          {unquote(__MODULE__).FakeProtocol, instance_pid} = instance

          Process.exit(instance_pid, :shutdown)

          send(__MODULE__, {:instance, instance})
        end
      end

      Process.register(self(), StartInstanceTestEndInstanceExitedTest)

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert_received {:instance, {FakeProtocol, instance_pid} = instance}

      assert io =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be running, but it exited with reason:\n"

      assert io =~ "\n     shutdown\n"
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
    end

    test "when test ends when instance doesn't exist" do
      defmodule StartInstanceTestEndInstanceDoesNotExistTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> :ok end
            )

          {unquote(__MODULE__).FakeProtocol, instance_pid} = instance

          Process.exit(instance_pid, :shutdown)
          TestServer.InstanceManager.delete_instance_entry(instance)

          send(__MODULE__, {:instance, instance})
        end
      end

      Process.register(self(), StartInstanceTestEndInstanceDoesNotExistTest)

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert_received {:instance, {FakeProtocol, instance_pid}}

      assert io =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be a TestServer-managed instance"
    end

    test "when test ends when verify_instance_fn raises exception" do
      defmodule StartInstanceTestEndVerifyInstanceFnFailsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> raise "boom" end
            )

          send(__MODULE__, {:instance, instance})
        end
      end

      Process.register(self(), StartInstanceTestEndVerifyInstanceFnFailsTest)

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "** (RuntimeError) boom"
      assert_received {:instance, {FakeProtocol, instance_pid} = instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance_pid)
    end

    test "when test ends when verify_instance_fn callback exits" do
      defmodule StartInstanceTestEndVerifyExitsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> exit(:boom) end
            )

          send(__MODULE__, {:instance, instance})
        end
      end

      Process.register(self(), StartInstanceTestEndVerifyExitsTest)

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "** (exit) :boom"
      assert_received {:instance, {FakeProtocol, instance_pid} = instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance_pid)
    end

    test "when test ends when protocol module stop raises exception" do
      defmodule StartInstanceTestEndStoppingInstanceFailsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance ->
                Process.put({unquote(__MODULE__).FakeProtocol, :raise_on_stop}, true)

                :ok
              end
            )

          send(__MODULE__, {:instance, instance})
        end
      end

      Process.register(self(), StartInstanceTestEndStoppingInstanceFailsTest)
      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "** (RuntimeError) boom"
      assert_received {:instance, {FakeProtocol, instance_pid} = instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance_pid)
    end

    test "when test ends when has many error reports" do
      defmodule StartInstanceTestEndVerifyManyErrorsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn _instance -> :ok end
            )

          {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

          TestServer.report_error(
            instance,
            {ArgumentError.exception("error without stacktrace"), []},
            suppress_warning: true
          )

          TestServer.report_error(
            instance,
            {ArgumentError.exception("error with stacktrace"), stacktrace},
            suppress_warning: true
          )

          send(__MODULE__, {:instance, instance})
        end
      end

      Process.register(self(), StartInstanceTestEndVerifyManyErrorsTest)
      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)

      assert io =~ "expected no errors, got:\n"
      assert io =~ "     ** (ArgumentError) error without stacktrace\n"
      assert io =~ "     ** (ArgumentError) error with stacktrace\n         (elixir"
      assert_received {:instance, {FakeProtocol, instance_pid} = instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance_pid)
    end

    test "when test ends when error reported inside verification" do
      defmodule StartInstanceTestEndErrorDuringVerifyTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn instance ->
                {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

                :ok =
                  TestServer.report_error(
                    instance,
                    {ArgumentError.exception("error with stacktrace"), stacktrace},
                    suppress_warning: true
                  )

                :ok
              end
            )

          TestServer.report_error(
            instance,
            {ArgumentError.exception("error without stacktrace"), []},
            suppress_warning: true
          )
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)

      assert io =~ "expected no errors, got:\n"
      assert io =~ "     ** (ArgumentError) error without stacktrace\n"
      assert io =~ "     ** (ArgumentError) error with stacktrace\n         (elixir"
    end
  end

  describe "assert_instance_alive!/1" do
    test "when instance entry running when process is not alive" do
      {:ok, instance} = TestServer.start_instance(FakeProtocol, [], fn _instance -> :ok end)
      :ok = delete_instance_entry_on_exit(instance)
      manager_pid = Process.whereis(TestServer.InstanceManager)
      {FakeProtocol, instance_pid} = instance

      task =
        with_suspended_process(manager_pid, fn ->
          task =
            Task.async(fn ->
              error =
                assert_raise RuntimeError, fn ->
                  TestServer.assert_instance_alive!(instance)
                end

              {:error, error}
            end)

          :ok = subscribe_message_inbox(manager_pid)

          assert_receive {^manager_pid, {:"$gen_call", _from, {:fetch_entry, ^instance}}}
          assert Process.exit(instance_pid, :kill)

          task
        end)

      assert {:error, error} = Task.await(task)
      message = Exception.message(error)

      assert message =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be running, but it exited with reason:\n\nkilled"
    end
  end

  describe "stop_instance/2" do
    test "when instance doesn't exist" do
      instance_pid = self()
      instance = {FakeProtocol, self()}

      error =
        assert_raise RuntimeError, fn -> assert TestServer.stop_instance(instance) == :ok end

      assert Exception.message(error) =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be a TestServer-managed instance"
    end

    test "with stopped instance" do
      {:ok, instance} = TestServer.start_instance(FakeProtocol, [], fn _instance -> :ok end)
      {FakeProtocol, instance_pid} = instance
      :ok = TestServer.stop_instance(instance)

      error =
        assert_raise RuntimeError, fn ->
          TestServer.stop_instance(instance)
        end

      message = Exception.message(error)

      assert message =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be running, but it was stopped at:"

      assert message =~ ~r/test\/test_server_test\.exs:\d+/
      assert message =~ "TestServerTest.\"test stop_instance/2 with stopped instance\"/1"
    end

    test "with exited instance" do
      {:ok, instance} = TestServer.start_instance(FakeProtocol, [], fn _instance -> :ok end)
      :ok = delete_instance_entry_on_exit(instance)
      {FakeProtocol, instance_pid} = instance
      monitor = Process.monitor(instance_pid)
      true = Process.exit(instance_pid, {:shutdown, :normal})

      assert_receive {:DOWN, ^monitor, :process, ^instance_pid, {:shutdown, :normal}}

      error =
        assert_raise RuntimeError, fn ->
          TestServer.stop_instance(instance)
        end

      assert Exception.message(error) =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be running, but it exited with reason:\n\nshutdown: :normal"
    end

    test "with running instance when instance process not alive" do
      {:ok, instance} = TestServer.start_instance(FakeProtocol, [], fn _instance -> :ok end)
      :ok = delete_instance_entry_on_exit(instance)
      {FakeProtocol, instance_pid} = instance
      manager_pid = Process.whereis(TestServer.InstanceManager)
      monitor = Process.monitor(instance_pid)

      task =
        with_suspended_process(manager_pid, fn ->
          task =
            Task.async(fn ->
              error =
                assert_raise RuntimeError, fn ->
                  TestServer.stop_instance(instance)
                end

              {:error, error}
            end)

          :ok = subscribe_message_inbox(manager_pid)

          assert_receive {^manager_pid,
                          {:"$gen_call", _from, {:stop_instance, ^instance, _stacktrace}}}

          assert Process.exit(instance_pid, :shutdown)
          assert_receive {:DOWN, ^monitor, :process, ^instance_pid, :shutdown}

          task
        end)

      assert {:error, error} = Task.await(task)

      assert Exception.message(error) =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be running, but it exited with reason:\n\nshutdown\n"
    end

    test "with running instance when exits abnormally" do
      {:ok, instance} = TestServer.start_instance(FakeProtocol, [], fn _instance -> :ok end)
      :ok = delete_instance_entry_on_exit(instance)
      {FakeProtocol, instance_pid} = instance
      supervisor_pid = Process.whereis(TestServer.InstanceSupervisor)
      monitor = Process.monitor(instance_pid)

      task =
        with_suspended_process(supervisor_pid, fn ->
          task =
            Task.async(fn ->
              error =
                assert_raise RuntimeError, fn ->
                  TestServer.stop_instance(instance)
                end

              {:error, error}
            end)

          :ok = subscribe_message_inbox(supervisor_pid)

          assert_receive {^supervisor_pid,
                          {:"$gen_call", _from, {:terminate_child, ^instance_pid}}}

          assert Process.exit(instance_pid, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^instance_pid, :killed}

          task
        end)

      assert {:error, error} = Task.await(task)

      assert Exception.message(error) =~
               "expected TestServerTest.FakeProtocol.Instance #{inspect(instance_pid)} to be running, but it exited with reason:\n\nkilled\n"
    end

    test "when test ends" do
      defmodule StopInstanceTestEndsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} =
            TestServer.start_instance(
              unquote(__MODULE__).FakeProtocol,
              [],
              fn instance ->
                send(__MODULE__, {:verified, instance})
              end
            )

          assert TestServer.stop_instance(instance) == :ok

          send(__MODULE__, {:instance, instance})
        end
      end

      Process.register(self(), StopInstanceTestEndsTest)

      capture_io(fn ->
        assert %{failures: 0} = ExUnit.run()
      end)

      assert_received {:instance, {FakeProtocol, instance_pid} = instance}
      refute_received {:verified, ^instance}
      assert TestServer.InstanceManager.fetch_instance_entry(instance) == {:error, :not_found}
      refute Process.alive?(instance_pid)
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

  # Prevents the normal TestServer on_exit callback from running by overriding
  # it
  defp delete_instance_entry_on_exit(instance) do
    ExUnit.Callbacks.on_exit({TestServer, instance}, fn ->
      TestServer.InstanceManager.delete_instance_entry(instance)
    end)
  end

  defp with_suspended_process(pid, fun) do
    :ok = :sys.suspend(pid)

    try do
      fun.()
    after
      :sys.resume(pid)
    end
  end

  defp subscribe_message_inbox(pid) do
    test_pid = self()

    Task.start_link(fn ->
      Enum.reduce(0..100, 0, fn _, index ->
        send_messages(test_pid, pid, index)
      end)
    end)

    :ok
  end

  defp send_messages(test_pid, pid, index) do
    case Process.alive?(pid) do
      true ->
        :timer.sleep(1)

        {:messages, messages} = Process.info(pid, :messages)

        Enum.each(
          Enum.slice(messages, index..-1//1),
          fn message -> send(test_pid, {pid, message}) end
        )

        length(messages)

      false ->
        exit(:normal)
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
