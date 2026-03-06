defmodule TestServer.SSHTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias TestServer.SSHClient

  describe "start/1" do
    test "auto-assigns port" do
      {:ok, instance} = TestServer.SSH.start()
      {_host, port} = TestServer.SSH.address(instance)
      assert is_integer(port) and port > 0
    end

    test "multiple independent instances have different ports" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, instance_2} = TestServer.SSH.start()
      {_, port1} = TestServer.SSH.address(instance_1)
      {_, port2} = TestServer.SSH.address(instance_2)
      refute port1 == port2
    end
  end

  describe "exec/1" do
    test "default handler returns exit 0 with empty output" do
      TestServer.SSH.exec([])

      {host, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"test")
      assert SSHClient.exec(conn, "anything") == {0, "", ""}
      :ssh.close(conn)
    end

    test "to: function receives command and returns output" do
      TestServer.SSH.exec(to: fn cmd, state -> {:reply, {0, "got: #{cmd}", ""}, state} end)

      {host, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"test")
      assert SSHClient.exec(conn, "ls") == {0, "got: ls", ""}
      :ssh.close(conn)
    end

    test "returns exit code and stderr" do
      TestServer.SSH.exec(to: fn _cmd, state -> {:reply, {1, "", "error\n"}, state} end)

      {host, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"test")
      assert SSHClient.exec(conn, "fail") == {1, "", "error\n"}
      :ssh.close(conn)
    end

    test "match: filters which handler runs" do
      TestServer.SSH.exec(
        match: fn cmd, _state -> cmd == "ls" end,
        to: fn _cmd, state -> {:reply, {0, "matched\n", ""}, state} end
      )

      {host, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"test")
      assert SSHClient.exec(conn, "ls") == {0, "matched\n", ""}
      :ssh.close(conn)
    end

    test "FIFO consumption order" do
      TestServer.SSH.exec(to: fn _cmd, state -> {:reply, {0, "first\n", ""}, state} end)
      TestServer.SSH.exec(to: fn _cmd, state -> {:reply, {0, "second\n", ""}, state} end)

      {host, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"test")
      assert SSHClient.exec(conn, "cmd") == {0, "first\n", ""}
      assert SSHClient.exec(conn, "cmd") == {0, "second\n", ""}
      :ssh.close(conn)
    end

    test "unmatched request reports error at test exit" do
      defmodule UnmatchedExecTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.exec(
            match: fn cmd, _state -> cmd == "ls" end,
            to: fn _cmd, state -> {:reply, {0, "ok", ""}, state} end
          )

          {host, port} = TestServer.SSH.address()
          {:ok, conn} = TestServer.SSHClient.connect(host, port, user: ~c"test")
          TestServer.SSHClient.exec(conn, "not-ls")
          :ssh.close(conn)
        end
      end

      log =
        capture_io(:stderr, fn ->
          capture_io(fn -> ExUnit.run() end)
        end)

      assert log =~ "received an unexpected SSH exec request"
    end

    test "unconsumed handler raises at test exit" do
      defmodule UnconsumedExecTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.exec(to: fn _cmd, state -> {:reply, {0, "ok", ""}, state} end)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "did not receive exec requests"
    end
  end

  describe "shell/1" do
    test "echoes data by default" do
      TestServer.SSH.shell([])

      {host, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"test")
      ch = SSHClient.open_shell(conn)
      SSHClient.send(conn, ch, "hello\n")
      assert SSHClient.recv(ch) == {:ok, "hello\n"}
      :ssh.close(conn)
    end

    test "to: function receives data and returns reply" do
      TestServer.SSH.shell(to: fn _data, state -> {:reply, "pong\n", state} end)

      {host, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"test")
      ch = SSHClient.open_shell(conn)
      SSHClient.send(conn, ch, "ping\n")
      assert SSHClient.recv(ch) == {:ok, "pong\n"}
      :ssh.close(conn)
    end

    test "match: filters which handler runs" do
      TestServer.SSH.shell(
        match: fn data, _state -> data == "ping\n" end,
        to: fn _data, state -> {:reply, "pong\n", state} end
      )

      {host, port} = TestServer.SSH.address()
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"test")
      ch = SSHClient.open_shell(conn)
      SSHClient.send(conn, ch, "ping\n")
      assert SSHClient.recv(ch) == {:ok, "pong\n"}
      :ssh.close(conn)
    end
  end

  describe "credentials - no auth" do
    test "accepts any user without credentials option" do
      {:ok, instance} = TestServer.SSH.start()
      TestServer.SSH.exec(instance, to: fn _cmd, state -> {:reply, {0, "ok", ""}, state} end)

      {host, port} = TestServer.SSH.address(instance)
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"anyone")
      assert SSHClient.exec(conn, "cmd") == {0, "ok", ""}
      :ssh.close(conn)
    end
  end

  describe "credentials - password auth" do
    test "accepts valid password" do
      {:ok, instance} = TestServer.SSH.start(credentials: [{"alice", "secret"}])
      TestServer.SSH.exec(instance, to: fn _cmd, state -> {:reply, {0, "ok", ""}, state} end)

      {host, port} = TestServer.SSH.address(instance)
      {:ok, conn} = SSHClient.connect(host, port, user: ~c"alice", password: ~c"secret")
      assert SSHClient.exec(conn, "cmd") == {0, "ok", ""}
      :ssh.close(conn)
    end

    test "rejects invalid password" do
      {:ok, _instance} = TestServer.SSH.start(credentials: [{"alice", "secret"}])
      {host, port} = TestServer.SSH.address()
      assert {:error, _} = SSHClient.connect(host, port, user: ~c"alice", password: ~c"wrong")
    end

    test "rejects unknown user" do
      {:ok, _instance} = TestServer.SSH.start(credentials: [{"alice", "secret"}])
      {host, port} = TestServer.SSH.address()
      assert {:error, _} = SSHClient.connect(host, port, user: ~c"bob", password: ~c"secret")
    end
  end

  describe "credentials - public key auth" do
    setup do
      private_key = :public_key.generate_key({:rsa, 2048, 65_537})
      {:RSAPrivateKey, _, modulus, public_exp, _, _, _, _, _, _, _} = private_key
      public_key = {:RSAPublicKey, modulus, public_exp}

      public_pem =
        :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, public_key)])

      user_dir = Path.join(System.tmp_dir!(), "ssh_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(user_dir)

      private_pem =
        :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

      id_rsa_path = Path.join(user_dir, "id_rsa")
      File.write!(id_rsa_path, private_pem)
      File.chmod!(id_rsa_path, 0o600)

      on_exit(fn -> File.rm_rf!(user_dir) end)

      {:ok, public_pem: public_pem, user_dir: user_dir}
    end

    test "accepts valid public key", %{public_pem: public_pem, user_dir: user_dir} do
      {:ok, instance} =
        TestServer.SSH.start(credentials: [{"bob", :public_key, public_pem}])

      TestServer.SSH.exec(instance, to: fn _cmd, state -> {:reply, {0, "ok", ""}, state} end)

      {host, port} = TestServer.SSH.address(instance)

      {:ok, conn} =
        SSHClient.connect(host, port,
          user: ~c"bob",
          user_dir: String.to_charlist(user_dir),
          auth_methods: ~c"publickey"
        )

      assert SSHClient.exec(conn, "cmd") == {0, "ok", ""}
      :ssh.close(conn)
    end

    test "rejects unknown public key", %{user_dir: user_dir} do
      other_key = :public_key.generate_key({:rsa, 2048, 65_537})
      {:RSAPrivateKey, _, modulus, public_exp, _, _, _, _, _, _, _} = other_key
      other_public_key = {:RSAPublicKey, modulus, public_exp}

      other_public_pem =
        :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, other_public_key)])

      {:ok, _instance} =
        TestServer.SSH.start(credentials: [{"bob", :public_key, other_public_pem}])

      {host, port} = TestServer.SSH.address()

      assert {:error, _} =
               SSHClient.connect(host, port,
                 user: ~c"bob",
                 user_dir: String.to_charlist(user_dir),
                 auth_methods: ~c"publickey"
               )
    end
  end

  describe "multi-instance" do
    test "error when multiple instances and no explicit instance arg" do
      {:ok, _instance_1} = TestServer.SSH.start()
      {:ok, _instance_2} = TestServer.SSH.start()

      assert_raise RuntimeError, ~r/Multiple.*running.*pass instance/, fn ->
        TestServer.SSH.address()
      end
    end

    test "explicit instance arg works with multiple instances" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, instance_2} = TestServer.SSH.start()

      {_, port1} = TestServer.SSH.address(instance_1)
      {_, port2} = TestServer.SSH.address(instance_2)

      refute port1 == port2
    end
  end
end
