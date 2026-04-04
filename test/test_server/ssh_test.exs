defmodule TestServer.SSHTest do
  use ExUnit.Case

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias __MODULE__.SSHClient

  describe "start/1" do
    test "with invalid port" do
      assert_raise RuntimeError, ~r/Invalid port, got: :invalid/, fn ->
        TestServer.SSH.start(port: :invalid)
      end

      assert_raise RuntimeError, ~r/Invalid port, got: 65536/, fn ->
        TestServer.SSH.start(port: 65_536)
      end

      assert_raise RuntimeError, ~r/Could not listen to port 2222, because: :eaddrinuse/, fn ->
        TestServer.SSH.start(port: 2222)
        TestServer.SSH.start(port: 2222)
      end
    end

    test "starts with multiple ports" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, instance_2} = TestServer.SSH.start()

      refute instance_1 == instance_2

      {_, port_1} = TestServer.SSH.address(instance_1)
      {_, port_2} = TestServer.SSH.address(instance_2)

      refute port_1 == port_2
    end

    test "starts with custom `:host_key`" do
      host_key = :public_key.generate_key({:rsa, 2048, 65_537})
      {:ok, _instance} = TestServer.SSH.start(host_key: host_key)
      TestServer.SSH.add()

      assert {0, "test", ""} = ssh_exec!("test")
    end
  end

  describe "stop/1" do
    test "when not running" do
      assert_raise RuntimeError, "No current TestServer.SSH.Instance running", fn ->
        TestServer.SSH.stop()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     {:ok, instance} = TestServer.SSH.start()

                     assert :ok = TestServer.SSH.stop()

                     TestServer.SSH.stop(instance)
                   end
    end

    test "stops" do
      {:ok, pid} = TestServer.SSH.start()

      assert :ok = TestServer.SSH.stop()
      refute Process.alive?(pid)

      assert {:error, _} = ssh_exec("test")
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, _instance_2} = TestServer.SSH.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SSH\.stop\/0`/,
                   fn ->
                     TestServer.SSH.stop()
                   end

      assert :ok = TestServer.SSH.stop(instance_1)
      assert :ok = TestServer.SSH.stop()
    end
  end

  describe "address/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.SSH.Instance running", fn ->
        TestServer.SSH.address()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     {:ok, instance} = TestServer.SSH.start()

                     assert :ok = TestServer.SSH.stop()

                     TestServer.SSH.address(instance)
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, instance_2} = TestServer.SSH.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SSH\.address\/0`/,
                   fn ->
                     TestServer.SSH.address()
                   end

      refute TestServer.SSH.address(instance_1) == TestServer.SSH.address(instance_2)
    end

    test "produces address" do
      {:ok, _instance} = TestServer.SSH.start()

      assert {"localhost", port} = TestServer.SSH.address()
      assert is_integer(port)
    end
  end

  describe "channel/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.SSH.Instance running", fn ->
        TestServer.SSH.channel()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     {:ok, instance} = TestServer.SSH.start()

                     assert :ok = TestServer.SSH.stop()

                     TestServer.SSH.channel(instance)
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, _instance_2} = TestServer.SSH.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SSH\.channel\/0`/,
                   fn ->
                     TestServer.SSH.channel()
                   end

      assert {:ok, _channel} = TestServer.SSH.channel(instance_1)
    end

    test "opens channel" do
      {:ok, _instance} = TestServer.SSH.start()
      assert {:ok, channel} = TestServer.SSH.channel()
      TestServer.SSH.add(channel)

      {_, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(~c"localhost", port)
      {:ok, ch} = SSHClient.open_channel(conn)
      assert {0, "test", ""} = SSHClient.exec(conn, ch, "test")
      SSHClient.close(conn)
    end
  end

  describe "add/2" do
    test "when instance not running" do
      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     {:ok, _instance} = TestServer.SSH.start()
                     {:ok, channel} = TestServer.SSH.channel()

                     assert :ok = TestServer.SSH.stop()

                     TestServer.SSH.add(channel)
                   end
    end

    test "with invalid options" do
      {:ok, _instance} = TestServer.SSH.start()

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.SSH.add(match: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.SSH.add(to: :invalid)
      end
    end

    test "with default callback function" do
      {:ok, _instance} = TestServer.SSH.start()
      TestServer.SSH.add()

      assert {0, "hello", ""} = ssh_exec!("hello")
    end

    test "with callback function" do
      {:ok, _instance} = TestServer.SSH.start()

      TestServer.SSH.add(
        to: fn {_type, input}, state ->
          {:reply, "got: #{input}", state}
        end
      )

      assert {0, "got: test", ""} = ssh_exec!("test")
    end

    test "with match function" do
      {:ok, _instance} = TestServer.SSH.start()
      TestServer.SSH.add(match: fn {_type, input}, _state -> input == "deploy" end)

      assert {0, "deploy", ""} = ssh_exec!("deploy")
    end

    test "with match and callback function" do
      {:ok, _instance} = TestServer.SSH.start()

      TestServer.SSH.add(
        match: fn {_type, input}, _state -> input == "deploy" end,
        to: fn _msg, state ->
          {:reply, "deployed!", state}
        end
      )

      assert {0, "deployed!", ""} = ssh_exec!("deploy")
    end

    test "with `:exit_status` code" do
      {:ok, _instance} = TestServer.SSH.start()

      TestServer.SSH.add(
        to: fn _msg, state ->
          {:reply, {"error output", exit_status: 1}, state}
        end
      )

      assert {1, "error output", ""} = ssh_exec!("fail")
    end

    test "with `:stderr`" do
      {:ok, _instance} = TestServer.SSH.start()

      TestServer.SSH.add(
        to: fn _msg, state ->
          {:reply, {"stdout data", stderr: "stderr data"}, state}
        end
      )

      assert {0, "stdout data", "stderr data"} = ssh_exec!("warn")
    end

    test "with `:ok` response" do
      {:ok, _instance} = TestServer.SSH.start()

      TestServer.SSH.add(
        to: fn _msg, state ->
          {:ok, state}
        end
      )

      assert {0, "", ""} = ssh_exec!("silent")
    end

    test "with shell and exec on same connection" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.channel()

      TestServer.SSH.add(channel,
        match: fn {:exec, input}, _state -> input == "cmd" end,
        to: fn _msg, state -> {:reply, "exec result", state} end
      )

      TestServer.SSH.add(channel,
        match: fn {:data, input}, _state -> input == "shell msg" end,
        to: fn _msg, state -> {:reply, "shell result", state} end
      )

      {_, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(~c"localhost", port)

      # Exec first
      {:ok, ch_1} = SSHClient.open_channel(conn)
      assert {0, "exec result", ""} = SSHClient.exec(conn, ch_1, "cmd")

      # Then shell on same connection
      {:ok, ch_2} = SSHClient.open_channel(conn)
      {:ok, conn, ch_2} = SSHClient.open_shell(conn, ch_2)
      :ok = SSHClient.send_shell(conn, ch_2, "shell msg")
      assert {:ok, "shell result"} = SSHClient.recv_shell(conn, ch_2)

      SSHClient.close(conn)
    end

    test "with match filtering" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.channel()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "skip" end,
        to: fn _msg, state -> {:reply, "wrong", state} end
      )

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "target" end,
        to: fn _msg, state -> {:reply, "right", state} end
      )

      {_, port} = TestServer.SSH.address()

      {:ok, conn} = SSHClient.connect(~c"localhost", port)
      {:ok, ch_1} = SSHClient.open_channel(conn)
      assert {0, "right", ""} = SSHClient.exec(conn, ch_1, "target")

      {:ok, ch_2} = SSHClient.open_channel(conn)
      assert {0, "wrong", ""} = SSHClient.exec(conn, ch_2, "skip")
      SSHClient.close(conn)
    end

    test "with initial state" do
      {:ok, _instance} = TestServer.SSH.start()

      TestServer.SSH.add(
        to: fn {_type, _input}, state ->
          {:reply, "state: #{inspect(state)}", state}
        end
      )

      assert {0, "state: nil", ""} = ssh_exec!("anything")
    end

    test "with state threading" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.channel()

      TestServer.SSH.add(channel,
        to: fn {_type, _input}, nil ->
          {:reply, "first", 1}
        end
      )

      TestServer.SSH.add(channel,
        to: fn {_type, _input}, state ->
          {:reply, "count: #{state}", state + 1}
        end
      )

      {_, port} = TestServer.SSH.address()

      {:ok, conn} = SSHClient.connect(~c"localhost", port)
      {:ok, ch} = SSHClient.open_channel(conn)
      {:ok, conn, ch} = SSHClient.open_shell(conn, ch)

      :ok = SSHClient.send_shell(conn, ch, "a")
      assert {:ok, "first"} = SSHClient.recv_shell(conn, ch)

      :ok = SSHClient.send_shell(conn, ch, "b")
      assert {:ok, "count: 1"} = SSHClient.recv_shell(conn, ch)

      SSHClient.close(conn)
    end

    test "with match receiving state" do
      {:ok, _instance} = TestServer.SSH.start()

      TestServer.SSH.add(
        match: fn {:exec, input}, nil -> input == "go" end,
        to: fn _msg, state -> {:reply, "matched", state} end
      )

      assert {0, "matched", ""} = ssh_exec!("go")
    end

    test "with multiple channels" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel_1} = TestServer.SSH.channel()
      {:ok, channel_2} = TestServer.SSH.channel()

      TestServer.SSH.add(channel_1,
        to: fn _msg, state -> {:reply, "channel1", state} end
      )

      TestServer.SSH.add(channel_2,
        to: fn _msg, state -> {:reply, "channel2", state} end
      )

      {_, port} = TestServer.SSH.address()

      {:ok, conn_1} = SSHClient.connect(~c"localhost", port)
      {:ok, conn_2} = SSHClient.connect(~c"localhost", port)

      {:ok, ch_1} = SSHClient.open_channel(conn_1)
      assert {0, "channel1", ""} = SSHClient.exec(conn_1, ch_1, "test")
      {:ok, ch_2} = SSHClient.open_channel(conn_2)
      assert {0, "channel2", ""} = SSHClient.exec(conn_2, ch_2, "test")

      SSHClient.close(conn_1)
      SSHClient.close(conn_2)
    end

    test "with connection reuse" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.channel()

      TestServer.SSH.add(channel, to: fn _msg, state -> {:reply, "first", state} end)
      TestServer.SSH.add(channel, to: fn _msg, state -> {:reply, "second", state} end)

      {_, port} = TestServer.SSH.address()

      {:ok, conn} = SSHClient.connect(~c"localhost", port)

      # Two execs on same connection reuse the channel_ref
      {:ok, ch_1} = SSHClient.open_channel(conn)
      assert {0, "first", ""} = SSHClient.exec(conn, ch_1, "a")
      {:ok, ch_2} = SSHClient.open_channel(conn)
      assert {0, "second", ""} = SSHClient.exec(conn, ch_2, "b")

      SSHClient.close(conn)
    end

    test "with unconsumed handlers" do
      defmodule UnconsumedHandlersTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start()

          TestServer.SSH.add(match: fn {_type, input}, _state -> input == "expected-command" end)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "did not receive expected messages"
    end

    test "with no channels registered" do
      defmodule NoChannelRegisteredTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)

          unquote(__MODULE__).ssh_exec("surprise")
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "no channels were registered"
    end

    test "with all channels already in use" do
      defmodule NoAvailableChannelTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)
          TestServer.SSH.add()

          unquote(__MODULE__).ssh_exec("first")
          unquote(__MODULE__).ssh_exec("second")
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "all registered channels are already in use"
    end

    test "with unexpected message" do
      defmodule UnexpectedMessageTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)

          TestServer.SSH.add(match: fn {_type, input}, _state -> input == "first" end)

          {_, port} = TestServer.SSH.address()
          {:ok, conn} = SSHClient.connect(~c"localhost", port)
          {:ok, ch_1} = SSHClient.open_channel(conn)
          SSHClient.exec(conn, ch_1, "first")
          {:ok, ch_2} = SSHClient.open_channel(conn)
          SSHClient.exec(conn, ch_2, "second")
          SSHClient.close(conn)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "received an unexpected SSH message"
    end

    test "with mismatched type" do
      defmodule MismatchedTypeTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)

          TestServer.SSH.add(match: fn {:data, input}, _state -> input == "data" end)

          unquote(__MODULE__).ssh_exec("data")
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "received an unexpected SSH message"
    end

    test "with callback function raising exception" do
      defmodule CallbackRaiseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)

          TestServer.SSH.add(to: fn _msg, _state -> raise "boom" end)

          unquote(__MODULE__).ssh_exec("test")
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
    end

    test "with callback function raising exception in shell" do
      defmodule CallbackRaiseShellTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)

          TestServer.SSH.add(to: fn _msg, _state -> raise "shell boom" end)

          {_, port} = TestServer.SSH.address()
          {:ok, conn} = SSHClient.connect(~c"localhost", port)
          {:ok, ch} = SSHClient.open_channel(conn)
          {:ok, conn, ch} = SSHClient.open_shell(conn, ch)

          :ok = SSHClient.send_shell(conn, ch, "test")
          {:ok, message} = SSHClient.recv_shell(conn, ch)
          assert message =~ "(RuntimeError) shell boom"

          SSHClient.close(conn)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "(RuntimeError) shell boom"
    end

    test "with invalid callback response" do
      defmodule InvalidCallbackResponseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)

          TestServer.SSH.add(to: fn _msg, _state -> :invalid end)

          unquote(__MODULE__).ssh_exec("test")
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "Invalid callback response, got: :invalid."
    end
  end

  describe "authentication" do
    test "no credentials accepts any connection" do
      {:ok, _instance} = TestServer.SSH.start()
      TestServer.SSH.add()

      assert {0, "test", ""} = ssh_exec!("test")
    end

    test "password authentication succeeds with correct credentials" do
      {:ok, _instance} = TestServer.SSH.start(credentials: [{"admin", "secret"}])
      TestServer.SSH.add()

      assert {0, "test", ""} =
               ssh_exec!("test", connect_opts: [user: ~c"admin", password: ~c"secret"])
    end

    test "password authentication fails with wrong credentials" do
      {:ok, _instance} = TestServer.SSH.start(credentials: [{"admin", "secret"}])

      {_, port} = TestServer.SSH.address()

      assert capture_log(fn ->
               assert {:error, _reason} =
                        SSHClient.connect(~c"localhost", port,
                          user: ~c"admin",
                          password: ~c"wrong"
                        )
             end) =~ "Unable to connect using the available authentication methods"
    end

    test "public key authentication succeeds" do
      # Generate a test key pair
      private_key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
      pem = :public_key.pem_encode([pem_entry])

      {:ok, _instance} = TestServer.SSH.start(credentials: [{"keyuser", {:public_key, pem}}])
      TestServer.SSH.add()

      # Write key to temp file for SSH client
      key_dir = System.tmp_dir!() |> Path.join("test_server_ssh_keys_#{:rand.uniform(100_000)}")
      File.mkdir_p!(key_dir)

      key_path = Path.join(key_dir, "id_rsa")
      File.write!(key_path, pem)

      try do
        assert {0, "test", ""} =
                 ssh_exec!("test",
                   connect_opts: [
                     user: ~c"keyuser",
                     user_dir: String.to_charlist(key_dir),
                     auth_methods: ~c"publickey"
                   ]
                 )
      after
        File.rm_rf!(key_dir)
      end
    end

    test "public key authentication fails" do
      # Generate a key pair for the server
      server_key = :public_key.generate_key({:rsa, 2048, 65_537})
      server_pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, server_key)
      server_pem = :public_key.pem_encode([server_pem_entry])

      {:ok, _instance} =
        TestServer.SSH.start(credentials: [{"keyuser", {:public_key, server_pem}}])

      # Generate a different key for the client
      client_key = :public_key.generate_key({:rsa, 2048, 65_537})
      client_pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, client_key)
      client_pem = :public_key.pem_encode([client_pem_entry])

      key_dir = System.tmp_dir!() |> Path.join("test_server_ssh_keys_#{:rand.uniform(100_000)}")
      File.mkdir_p!(key_dir)

      key_path = Path.join(key_dir, "id_rsa")
      File.write!(key_path, client_pem)

      try do
        {_, port} = TestServer.SSH.address()

        log =
          capture_log(fn ->
            assert {:error, _reason} =
                     SSHClient.connect(~c"localhost", port,
                       user: ~c"keyuser",
                       user_dir: String.to_charlist(key_dir),
                       auth_methods: ~c"publickey"
                     )
          end)

        assert log =~ "Unable to connect using the available authentication methods"
      after
        File.rm_rf!(key_dir)
      end
    end
  end

  def ssh_exec!(command, opts \\ []) do
    {:ok, result} = ssh_exec(command, opts)
    result
  end

  def ssh_exec(command, opts \\ []) do
    {_, port} = TestServer.SSH.address()
    connect_opts = Keyword.get(opts, :connect_opts, [])

    case SSHClient.connect(~c"localhost", port, connect_opts) do
      {:ok, conn} ->
        {:ok, ch} = SSHClient.open_channel(conn)
        result = SSHClient.exec(conn, ch, command)
        SSHClient.close(conn)
        {:ok, result}

      {:error, error} ->
        {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  defmodule SSHClient do
    @moduledoc false

    @default_opts [
      silently_accept_hosts: true,
      user: ~c"test",
      password: ~c"test",
      user_interaction: false
    ]

    def connect(host, port, opts \\ []) do
      host = if is_binary(host), do: String.to_charlist(host), else: host
      opts = Keyword.merge(@default_opts, opts)

      :ssh.connect(host, port, opts)
    end

    def open_channel(conn, timeout \\ 5000) do
      :ssh_connection.session_channel(conn, timeout)
    end

    def exec(conn, channel_id, command, timeout \\ 5000) do
      :success = :ssh_connection.exec(conn, channel_id, String.to_charlist(command), timeout)

      collect_exec_response(conn, channel_id, "", "", 0, timeout)
    end

    defp collect_exec_response(conn, channel_id, stdout, stderr, exit_code, timeout) do
      receive do
        {:ssh_cm, ^conn, {:data, ^channel_id, 0, data}} ->
          collect_exec_response(conn, channel_id, stdout <> data, stderr, exit_code, timeout)

        {:ssh_cm, ^conn, {:data, ^channel_id, 1, data}} ->
          collect_exec_response(conn, channel_id, stdout, stderr <> data, exit_code, timeout)

        {:ssh_cm, ^conn, {:exit_status, ^channel_id, code}} ->
          collect_exec_response(conn, channel_id, stdout, stderr, code, timeout)

        {:ssh_cm, ^conn, {:eof, ^channel_id}} ->
          collect_exec_response(conn, channel_id, stdout, stderr, exit_code, timeout)

        {:ssh_cm, ^conn, {:closed, ^channel_id}} ->
          {exit_code, stdout, stderr}
      after
        timeout -> {:error, :timeout}
      end
    end

    def open_shell(conn, channel_id) do
      :ok = :ssh_connection.shell(conn, channel_id)

      {:ok, conn, channel_id}
    end

    def send_shell(conn, channel_id, data) do
      :ssh_connection.send(conn, channel_id, data)
    end

    def recv_shell(conn, channel_id, timeout \\ 1000) do
      receive do
        {:ssh_cm, ^conn, {:data, ^channel_id, 0, data}} ->
          {:ok, to_string(data)}
      after
        timeout -> {:error, :timeout}
      end
    end

    def close(conn) do
      :ssh.close(conn)
    end
  end
end
