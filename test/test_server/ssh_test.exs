defmodule TestServer.SSHTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias TestServer.SSHClient

  describe "add/1" do
    test "default handler echoes input for exec" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()
      TestServer.SSH.add(channel)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "hello", ""} = SSHClient.exec(conn, "hello")
      SSHClient.close(conn)
    end

    test "default handler echoes input for shell" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()
      TestServer.SSH.add(channel)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      {:ok, conn, channel_id} = SSHClient.open_shell(conn)

      :ok = SSHClient.send_shell(conn, channel_id, "hello")
      assert {:ok, "hello"} = SSHClient.recv_shell(conn, channel_id)

      SSHClient.close(conn)
    end
  end

  describe "add/2 with match" do
    test "matches exact value for exec" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()
      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "deploy" end)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "deploy", ""} = SSHClient.exec(conn, "deploy")
      SSHClient.close(conn)
    end

    test "matches exact value for shell data" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()
      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "hello" end)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      {:ok, conn, channel_id} = SSHClient.open_shell(conn)

      :ok = SSHClient.send_shell(conn, channel_id, "hello")
      assert {:ok, "hello"} = SSHClient.recv_shell(conn, channel_id)

      SSHClient.close(conn)
    end

    test "matches with function" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> String.contains?(input, "git-") end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "git-upload-pack", ""} = SSHClient.exec(conn, "git-upload-pack")
      SSHClient.close(conn)
    end

    test "matches function" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> String.starts_with?(input, "deploy") end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "deploy prod", ""} = SSHClient.exec(conn, "deploy prod")
      SSHClient.close(conn)
    end

    test "custom to handler" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        to: fn {_type, input}, state ->
          {:reply, "got: #{input}", state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "got: test", ""} = SSHClient.exec(conn, "test")
      SSHClient.close(conn)
    end
  end

  describe "add/2 with match and to" do
    test "function match with custom handler" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "deploy" end,
        to: fn _msg, state ->
          {:reply, "deployed!", state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "deployed!", ""} = SSHClient.exec(conn, "deploy")
      SSHClient.close(conn)
    end

    test "prefix match with custom handler" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> String.starts_with?(input, "git") end,
        to: fn {_type, input}, state ->
          {:reply, "matched: #{input}", state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "matched: git push", ""} = SSHClient.exec(conn, "git push")
      SSHClient.close(conn)
    end

    test "anonymous function match with custom handler" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "secret" end,
        to: fn _msg, state ->
          {:reply, "found it", state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "found it", ""} = SSHClient.exec(conn, "secret")
      SSHClient.close(conn)
    end

    test "custom response with exit code" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "fail" end,
        to: fn _msg, state ->
          {:reply, {"error output", exit: 1}, state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {1, "error output", ""} = SSHClient.exec(conn, "fail")
      SSHClient.close(conn)
    end

    test "custom response with stderr" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "warn" end,
        to: fn _msg, state ->
          {:reply, {"stdout data", stderr: "stderr data"}, state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "stdout data", "stderr data"} = SSHClient.exec(conn, "warn")
      SSHClient.close(conn)
    end

    test ":ok response sends no output" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "silent" end,
        to: fn _msg, state ->
          {:ok, state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "", ""} = SSHClient.exec(conn, "silent")
      SSHClient.close(conn)
    end
  end

  describe "match with type tag" do
    test "match on :exec type only matches exec requests" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {:exec, input}, _state -> input == "exec-only" end,
        to: fn _msg, state -> {:reply, "exec matched", state} end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "exec matched", ""} = SSHClient.exec(conn, "exec-only")
      SSHClient.close(conn)
    end

    test "match on :data type only matches shell data" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {:data, input}, _state -> input == "shell-only" end,
        to: fn _msg, state -> {:reply, "shell matched", state} end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      {:ok, conn, channel_id} = SSHClient.open_shell(conn)

      :ok = SSHClient.send_shell(conn, channel_id, "shell-only")
      assert {:ok, "shell matched"} = SSHClient.recv_shell(conn, channel_id)

      SSHClient.close(conn)
    end

    test "ignoring type matches both exec and shell" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "first" end)
      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "second" end)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())

      # First handler consumed by exec
      assert {0, "first", ""} = SSHClient.exec(conn, "first")

      # Second handler consumed by shell
      {:ok, conn, channel_id} = SSHClient.open_shell(conn)
      :ok = SSHClient.send_shell(conn, channel_id, "second")
      assert {:ok, "second"} = SSHClient.recv_shell(conn, channel_id)

      SSHClient.close(conn)
    end

    test "mismatched type skips handler" do
      defmodule MismatchedTypeTest do
        use ExUnit.Case

        test "fails with unconsumed handler" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)
          {:ok, channel} = TestServer.SSH.open()

          TestServer.SSH.add(channel,
            match: fn {:data, input}, _state -> input == "data" end
          )

          {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
          SSHClient.exec(conn, "data")
          SSHClient.close(conn)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "received an unexpected SSH message"
    end
  end

  describe "handler ordering" do
    test "FIFO consumption — handlers consumed in registration order" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel, to: fn _msg, state -> {:reply, "first", state} end)
      TestServer.SSH.add(channel, to: fn _msg, state -> {:reply, "second", state} end)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "first", ""} = SSHClient.exec(conn, "a")
      assert {0, "second", ""} = SSHClient.exec(conn, "b")
      SSHClient.close(conn)
    end

    test "match filtering skips non-matching handlers" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "skip" end,
        to: fn _msg, state -> {:reply, "wrong", state} end
      )

      TestServer.SSH.add(channel,
        match: fn {_type, input}, _state -> input == "target" end,
        to: fn _msg, state -> {:reply, "right", state} end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "right", ""} = SSHClient.exec(conn, "target")

      # Now "skip" is still unconsumed — clean it up
      assert {0, "wrong", ""} = SSHClient.exec(conn, "skip")
      SSHClient.close(conn)
    end

    test "multiple handlers consumed across multiple exec calls" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "cmd1" end)
      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "cmd2" end)
      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "cmd3" end)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "cmd1", ""} = SSHClient.exec(conn, "cmd1")
      assert {0, "cmd2", ""} = SSHClient.exec(conn, "cmd2")
      assert {0, "cmd3", ""} = SSHClient.exec(conn, "cmd3")
      SSHClient.close(conn)
    end

    test "multiple handlers consumed across shell interactions" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "msg1" end)
      TestServer.SSH.add(channel, match: fn {_type, input}, _state -> input == "msg2" end)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      {:ok, conn, channel_id} = SSHClient.open_shell(conn)

      :ok = SSHClient.send_shell(conn, channel_id, "msg1")
      assert {:ok, "msg1"} = SSHClient.recv_shell(conn, channel_id)

      :ok = SSHClient.send_shell(conn, channel_id, "msg2")
      assert {:ok, "msg2"} = SSHClient.recv_shell(conn, channel_id)

      SSHClient.close(conn)
    end
  end

  describe "state threading" do
    test "channel state starts as nil" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        to: fn {_type, _input}, state ->
          {:reply, "state: #{inspect(state)}", state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "state: nil", ""} = SSHClient.exec(conn, "anything")
      SSHClient.close(conn)
    end

    test "state threads across sequential shell messages" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

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

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      {:ok, conn, channel_id} = SSHClient.open_shell(conn)

      :ok = SSHClient.send_shell(conn, channel_id, "a")
      assert {:ok, "first"} = SSHClient.recv_shell(conn, channel_id)

      :ok = SSHClient.send_shell(conn, channel_id, "b")
      assert {:ok, "count: 1"} = SSHClient.recv_shell(conn, channel_id)

      SSHClient.close(conn)
    end

    test "match receives tagged tuple and state" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        match: fn {:exec, input}, nil -> input == "go" end,
        to: fn _msg, state -> {:reply, "matched", state} end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "matched", ""} = SSHClient.exec(conn, "go")
      SSHClient.close(conn)
    end

    test "opts in data position with exit code" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      TestServer.SSH.add(channel,
        to: fn _msg, state ->
          {:reply, {"out", exit: 1}, state}
        end
      )

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {1, "out", ""} = SSHClient.exec(conn, "test")
      SSHClient.close(conn)
    end
  end

  describe "verification" do
    test "raises when handlers not consumed" do
      defmodule HandlersNotConsumedTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start()
          {:ok, channel} = TestServer.SSH.open()

          TestServer.SSH.add(channel,
            match: fn {_type, input}, _state -> input == "expected-command" end
          )
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "did not receive expected messages"
    end

    test "raises on unexpected channel with no open channels" do
      defmodule UnexpectedChannelTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)

          {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())

          try do
            SSHClient.exec(conn, "surprise")
          rescue
            MatchError -> :ok
          end

          SSHClient.close(conn)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "received an unexpected SSH channel"
    end

    test "raises on unexpected message when all handlers suspended" do
      defmodule AllHandlersSuspendedTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SSH.start(suppress_warning: true)
          {:ok, channel} = TestServer.SSH.open()

          TestServer.SSH.add(channel,
            match: fn {_type, input}, _state -> input == "first" end
          )

          {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
          SSHClient.exec(conn, "first")
          SSHClient.exec(conn, "second")
          SSHClient.close(conn)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "received an unexpected SSH message"
    end
  end

  describe "validation" do
    test "raises for non-function match" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()

      assert_raise ArgumentError, fn ->
        TestServer.SSH.add(channel, match: "deploy")
      end

      assert_raise ArgumentError, fn ->
        TestServer.SSH.add(channel, match: ~r/deploy/)
      end
    end
  end

  describe "authentication" do
    test "no credentials accepts any connection" do
      {:ok, _instance} = TestServer.SSH.start()
      {:ok, channel} = TestServer.SSH.open()
      TestServer.SSH.add(channel)

      {:ok, conn} = SSHClient.connect(~c"localhost", TestServer.SSH.port())
      assert {0, "test", ""} = SSHClient.exec(conn, "test")
      SSHClient.close(conn)
    end

    test "password authentication succeeds with correct credentials" do
      {:ok, _instance} = TestServer.SSH.start(credentials: [{"admin", "secret"}])
      {:ok, channel} = TestServer.SSH.open()
      TestServer.SSH.add(channel)

      {:ok, conn} =
        SSHClient.connect(~c"localhost", TestServer.SSH.port(),
          user: ~c"admin",
          password: ~c"secret"
        )

      assert {0, "test", ""} = SSHClient.exec(conn, "test")
      SSHClient.close(conn)
    end

    test "password authentication fails with wrong credentials" do
      {:ok, _instance} = TestServer.SSH.start(credentials: [{"admin", "secret"}])

      assert {:error, _reason} =
               SSHClient.connect(~c"localhost", TestServer.SSH.port(),
                 user: ~c"admin",
                 password: ~c"wrong"
               )
    end

    test "public key authentication succeeds" do
      # Generate a test key pair
      private_key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
      pem = :public_key.pem_encode([pem_entry])

      {:ok, _instance} = TestServer.SSH.start(credentials: [{"keyuser", {:public_key, pem}}])
      {:ok, channel} = TestServer.SSH.open()
      TestServer.SSH.add(channel)

      # Write key to temp file for SSH client
      key_dir = System.tmp_dir!() |> Path.join("test_server_ssh_keys_#{:rand.uniform(100_000)}")
      File.mkdir_p!(key_dir)

      key_path = Path.join(key_dir, "id_rsa")
      File.write!(key_path, pem)

      try do
        {:ok, conn} =
          SSHClient.connect(~c"localhost", TestServer.SSH.port(),
            user: ~c"keyuser",
            user_dir: String.to_charlist(key_dir),
            auth_methods: ~c"publickey"
          )

        assert {0, "test", ""} = SSHClient.exec(conn, "test")
        SSHClient.close(conn)
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
        assert {:error, _reason} =
                 SSHClient.connect(~c"localhost", TestServer.SSH.port(),
                   user: ~c"keyuser",
                   user_dir: String.to_charlist(key_dir),
                   auth_methods: ~c"publickey"
                 )
      after
        File.rm_rf!(key_dir)
      end
    end
  end

  describe "lifecycle" do
    test "auto-assigns port when port: 0" do
      {:ok, _instance} = TestServer.SSH.start(port: 0)
      port = TestServer.SSH.port()

      assert is_integer(port)
      assert port > 0
    end

    test "address returns localhost and port" do
      {:ok, _instance} = TestServer.SSH.start()
      {"localhost", port} = TestServer.SSH.address()

      assert is_integer(port)
      assert port > 0
    end

    test "port returns just the port number" do
      {:ok, _instance} = TestServer.SSH.start()
      port = TestServer.SSH.port()

      assert is_integer(port)
      assert port > 0
    end

    test "multiple instances are isolated" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, instance_2} = TestServer.SSH.start()

      refute instance_1 == instance_2

      port_1 = TestServer.SSH.port(instance_1)
      port_2 = TestServer.SSH.port(instance_2)
      refute port_1 == port_2

      {:ok, channel_1} = TestServer.SSH.open(instance_1)
      {:ok, channel_2} = TestServer.SSH.open(instance_2)

      TestServer.SSH.add(channel_1,
        to: fn _msg, state -> {:reply, "instance1", state} end
      )

      TestServer.SSH.add(channel_2,
        to: fn _msg, state -> {:reply, "instance2", state} end
      )

      {:ok, conn_1} = SSHClient.connect(~c"localhost", port_1)
      {:ok, conn_2} = SSHClient.connect(~c"localhost", port_2)

      assert {0, "instance1", ""} = SSHClient.exec(conn_1, "test")
      assert {0, "instance2", ""} = SSHClient.exec(conn_2, "test")

      SSHClient.close(conn_1)
      SSHClient.close(conn_2)
    end

    test "stop/0 stops current instance" do
      {:ok, pid} = TestServer.SSH.start()

      assert :ok = TestServer.SSH.stop()
      refute Process.alive?(pid)
    end
  end
end
