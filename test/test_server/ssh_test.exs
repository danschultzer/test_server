defmodule TestServer.SSHTest do
  use ExUnit.Case
  doctest TestServer.SSH

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias __MODULE__.SSHClient

  describe "start/1" do
    test "with invalid `:port` option" do
      assert_raise ArgumentError, ~r/expected a port, got: :invalid/, fn ->
        TestServer.SSH.start(port: :invalid)
      end
    end

    test "with multiple instances" do
      instance_1 = TestServer.SSH.start!()
      instance_2 = TestServer.SSH.start!()

      refute instance_1 == instance_2

      {_, port_1} = TestServer.SSH.address(instance_1)
      {_, port_2} = TestServer.SSH.address(instance_2)

      refute port_1 == port_2
    end

    test "with `:host_keys` option list" do
      host_key_1 = :public_key.generate_key({:rsa, 2048, 65_537})
      host_key_2 = :public_key.generate_key({:namedCurve, :secp521r1})

      {:RSAPrivateKey, _, other_mod, other_exp, _, _, _, _, _, _, _} =
        :public_key.generate_key({:rsa, 2048, 65_537})

      other_hostkey_fingerprint = :ssh.hostkey_fingerprint({:RSAPublicKey, other_mod, other_exp})

      TestServer.SSH.start!(host_keys: [host_key_1, host_key_2])

      [host_key_1_fingerprint, host_key_2_fingerprint] =
        Enum.map(TestServer.SSH.host_keys(), & &1.fingerprint)

      assert capture_log(fn ->
               assert SSHClient.connect(
                        TestServer.SSH.address(),
                        silently_accept_hosts: fn _peer, fingerprint ->
                          fingerprint == other_hostkey_fingerprint
                        end
                      ) == {:error, "Key exchange failed"}
             end) =~ "Key exchange failed"

      assert {:ok, _conn} =
               SSHClient.connect(
                 TestServer.SSH.address(),
                 silently_accept_hosts: fn _peer, fingerprint ->
                   fingerprint == host_key_2_fingerprint
                 end
               )

      assert {:ok, _conn} =
               SSHClient.connect(
                 TestServer.SSH.address(),
                 silently_accept_hosts: fn _peer, fingerprint ->
                   fingerprint == host_key_1_fingerprint
                 end
               )
    end

    test "with `:host_keys` option function" do
      host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
      {:RSAPrivateKey, _, mod, exp, _, _, _, _, _, _, _} = host_key
      hostkey_fingerprint = :ssh.hostkey_fingerprint({:RSAPublicKey, mod, exp})

      {:RSAPrivateKey, _, other_mod, other_exp, _, _, _, _, _, _, _} =
        :public_key.generate_key({:rsa, 2_048, 65_537})

      other_host_key_fingerprint = :ssh.hostkey_fingerprint({:RSAPublicKey, other_mod, other_exp})

      TestServer.SSH.start!(
        host_keys: fn _algorithm, _daemon_options ->
          {:ok, host_key}
        end
      )

      assert capture_log(fn ->
               assert {:error, "Key exchange failed"} =
                        SSHClient.connect(TestServer.SSH.address(),
                          silently_accept_hosts: fn _peer, fingerprint ->
                            fingerprint == other_host_key_fingerprint
                          end
                        )
             end) =~ "Verify host key: {error,fingerprint_check_failed}"

      assert capture_log(fn ->
               assert {:error, "Key exchange failed"} =
                        SSHClient.connect(TestServer.SSH.address(),
                          preferred_algorithms: [public_key: [:"ecdsa-sha2-nistp521"]]
                        )
             end) =~ "No common key algorithm"

      assert {:ok, _conn} =
               SSHClient.connect(TestServer.SSH.address(),
                 silently_accept_hosts: fn _peer, fingerprint ->
                   fingerprint == hostkey_fingerprint
                 end
               )
    end

    for algorithm <- ~w(
        rsa-sha2-256
        rsa-sha2-512
        ecdsa-sha2-nistp256
        ecdsa-sha2-nistp384
        ecdsa-sha2-nistp521
        ssh-ed25519
        ssh-ed448
      )a do
      test "with default `:host_keys` option using #{algorithm} algorithm" do
        TestServer.SSH.start!()

        assert capture_log(fn ->
                 assert {:error, "Key exchange failed"} =
                          SSHClient.connect(
                            TestServer.SSH.address(),
                            preferred_algorithms: [public_key: [:"ssh-dss"]]
                          )
               end) =~ "Key exchange failed"

        {:ok, conn} =
          SSHClient.connect(
            TestServer.SSH.address(),
            preferred_algorithms: [public_key: [unquote(algorithm)]]
          )

        {:algorithms, algs} = :ssh.connection_info(conn, :algorithms)

        assert Keyword.fetch!(algs, :hkey) == unquote(algorithm)
      end
    end

    test "with `:auth_keys` option list", context do
      {:RSAPrivateKey, _, mod, exp, _, _, _, _, _, _, _} =
        auth_key_1 = :public_key.generate_key({:rsa, 2048, 65_537})

      auth_key_1_public_key = {:RSAPublicKey, mod, exp}

      {:ECPrivateKey, _, _, oid, public_key, _} =
        auth_key_2 = :public_key.generate_key({:namedCurve, :secp256r1})

      auth_key_2_public_key = {{:ECPoint, public_key}, oid}
      user_dir = write_user_dir_pem!(context, auth_key_2)
      client_options = [user_dir: user_dir, auth_methods: "publickey"]

      TestServer.SSH.start!(
        auth_keys: [
          {nil, auth_key_1_public_key},
          {"user", auth_key_2_public_key}
        ]
      )

      assert capture_log(fn ->
               assert {:error, "Unable to connect using the available authentication methods"} =
                        SSHClient.connect(
                          TestServer.SSH.address(),
                          Keyword.put(client_options, :user, "other")
                        )
             end) =~ "User auth failed for: \"other\""

      assert {:ok, _conn} =
               SSHClient.connect(
                 TestServer.SSH.address(),
                 Keyword.put(client_options, :user, "user")
               )

      write_user_dir_pem!(context, auth_key_1)

      assert {:ok, _conn} =
               SSHClient.connect(
                 TestServer.SSH.address(),
                 Keyword.put(client_options, :user, "other")
               )
    end

    test "with `:auth_keys` option function", context do
      {:RSAPrivateKey, _, mod, exp, _, _, _, _, _, _, _} =
        auth_key = :public_key.generate_key({:rsa, 2048, 65_537})

      auth_key_public = {:RSAPublicKey, mod, exp}
      user_dir = write_user_dir_pem!(context, auth_key)
      client_options = [user_dir: user_dir, auth_methods: "publickey"]

      TestServer.SSH.start!(
        auth_keys: fn public_key, user, _daemon_options ->
          user == ~c"user" and public_key == auth_key_public
        end
      )

      assert capture_log(fn ->
               assert {:error, "Unable to connect using the available authentication methods"} =
                        SSHClient.connect(
                          TestServer.SSH.address(),
                          Keyword.put(client_options, :user, "other")
                        )
             end) =~ "User auth failed for: \"other\""

      assert {:ok, _conn} =
               SSHClient.connect(
                 TestServer.SSH.address(),
                 Keyword.put(client_options, :user, "user")
               )
    end

    test "with `:user_passwords` option" do
      TestServer.SSH.start!(user_passwords: [{"user", "pass"}])

      assert capture_log(fn ->
               assert SSHClient.connect(
                        TestServer.SSH.address(),
                        user: "user",
                        password: "invalid"
                      ) ==
                        {:error, "Unable to connect using the available authentication methods"}
             end) =~ "Unable to connect using the available authentication methods"

      assert capture_log(fn ->
               assert SSHClient.connect(
                        TestServer.SSH.address(),
                        user: "other",
                        password: "pass"
                      ) ==
                        {:error, "Unable to connect using the available authentication methods"}
             end) =~ "Unable to connect using the available authentication methods"

      assert {:ok, _conn} =
               SSHClient.connect(
                 TestServer.SSH.address(),
                 user: "user",
                 password: "pass",
                 auth_methods: "password"
               )
    end

    test "with `:no_auth_needed` option" do
      TestServer.SSH.start!(no_auth_needed: true)

      assert {:ok, _conn} = SSHClient.connect(TestServer.SSH.address())
    end

    test "with `ipfamily: :inet6` option" do
      TestServer.SSH.start!(ipfamily: :inet6)

      {:ok, conn} = SSHClient.connect(TestServer.SSH.address(), inet6: true)
      assert {ip, _port} = SSHClient.sockname(conn)
      assert ip == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "with `:daemon` option" do
      TestServer.SSH.start!(daemon: [max_sessions: 2])

      assert {:ok, _conn} = SSHClient.connect(TestServer.SSH.address())
      assert {:ok, _conn} = SSHClient.connect(TestServer.SSH.address())
      assert {:error, "Connection closed"} = SSHClient.connect(TestServer.SSH.address())
    end

    test "with `suppress_ssh_strict_kex_ordering_log: true` option" do
      :logger.remove_primary_filter(:test_server_suppress_ssh_strict_kex_ordering)
      TestServer.SSH.start!(suppress_ssh_strict_kex_ordering_log: true)

      assert %{filters: filters} = :logger.get_primary_config()
      assert List.keyfind(filters, :test_server_suppress_ssh_strict_kex_ordering, 0)

      assert capture_log(fn ->
               assert {:ok, _conn} = SSHClient.connect(TestServer.SSH.address())
             end) == ""

      :ok = TestServer.SSH.stop()

      assert %{filters: filters} = :logger.get_primary_config()
      refute List.keyfind(filters, :test_server_suppress_ssh_strict_kex_ordering, 0)
    end

    test "with `suppress_ssh_strict_kex_ordering_log: false` option" do
      :logger.remove_primary_filter(:test_server_suppress_ssh_strict_kex_ordering)
      TestServer.SSH.start!(suppress_ssh_strict_kex_ordering_log: false)

      assert %{filters: filters} = :logger.get_primary_config()
      refute List.keyfind(filters, :test_server_suppress_ssh_strict_kex_ordering, 0)

      assert capture_log(fn ->
               assert {:ok, _conn} = SSHClient.connect(TestServer.SSH.address())
             end) =~ "server will use strict KEX ordering"
    end

    test "when test ends" do
      {:ok, port} = TestServer.open_port([])

      on_exit(fn ->
        refute :gen_tcp.listen(port, []) == {:error, :eaddrinuse},
               "Port #{port} must be released after test ends"
      end)

      assert {:ok, _instance} = TestServer.SSH.start(port: port)
      assert {:error, :eaddrinuse} = :gen_tcp.listen(port, [])
    end
  end

  defp write_user_dir_pem!(context, key) do
    test_name =
      context.test
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")

    base_name =
      case key do
        {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} -> "id_rsa"
        {:ECPrivateKey, _, _, _, _, _} -> "id_ecdsa"
      end

    path = Path.join([System.tmp_dir!(), to_string(context.module), test_name])

    File.rm_rf!(path)
    File.mkdir_p!(path)

    SSHClient.write_user_dir_pem!(key, base_name, path)
  end

  describe "start!/1" do
    test "returns instance" do
      assert instance = TestServer.SSH.start!()
      assert is_pid(instance)
    end

    test "when start fails" do
      instance = TestServer.SSH.start!()
      port = instance |> TestServer.SSH.Instance.options() |> Keyword.fetch!(:port)

      assert_raise RuntimeError,
                   ~r/EXIT when starting TestServer.SSH instance on port #{port}/,
                   fn -> TestServer.SSH.start!(port: port) end
    end
  end

  describe "stop/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.SSH.Instance running", fn ->
        TestServer.SSH.stop()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.SSH.start!()
                     :ok = TestServer.SSH.stop()

                     TestServer.SSH.stop(instance)
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, _instance_2} = TestServer.SSH.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SSH\.stop\/0`/,
                   fn ->
                     TestServer.SSH.stop()
                   end

      assert TestServer.SSH.stop(instance_1) == :ok
      assert TestServer.SSH.stop() == :ok
    end

    test "stops" do
      instance = TestServer.SSH.start!()
      address = TestServer.SSH.address()

      assert TestServer.SSH.stop() == :ok
      refute Process.alive?(instance)
      assert {:error, reason} = SSHClient.connect(address)
      assert reason in [:econnrefused, :econnreset]
    end
  end

  describe "address/2" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.SSH.Instance running", fn ->
        TestServer.SSH.address()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.SSH.start!()
                     :ok = TestServer.SSH.stop()

                     TestServer.SSH.address(instance)
                   end
    end

    test "with multiple instances" do
      instance_1 = TestServer.SSH.start!()
      instance_2 = TestServer.SSH.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SSH\.address\/1`/,
                   fn ->
                     TestServer.SSH.address()
                   end

      refute TestServer.SSH.address(instance_1) == TestServer.SSH.address(instance_2)
    end

    test "returns" do
      TestServer.SSH.start!()

      assert {"localhost", port} = TestServer.SSH.address()
      assert is_integer(port)
    end

    test "with invalid `:host` option" do
      TestServer.SSH.start!()

      assert_raise RuntimeError, ~r/Invalid host, got: :invalid/, fn ->
        TestServer.SSH.address(host: :invalid)
      end
    end

    test "with `:host` option" do
      TestServer.SSH.start!()

      assert {"myserver.test", _port} = address = TestServer.SSH.address(host: "myserver.test")

      assert {:ok, _conn} = SSHClient.connect(address)
    end

    test "with `:host` option when started with `ipfamily: :inet6` option" do
      TestServer.SSH.start!(ipfamily: :inet6)

      assert {:ok, _conn} = SSHClient.connect(TestServer.SSH.address(), inet6: true)
    end
  end

  describe "channel/2" do
    test "when instance not running" do
      instance = TestServer.SSH.start!()
      :ok = TestServer.SSH.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     TestServer.SSH.channel(instance, [])
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.SSH.start()
      {:ok, _instance_2} = TestServer.SSH.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SSH\.channel\/1`/,
                   fn ->
                     TestServer.SSH.channel()
                   end

      assert TestServer.SSH.channel(instance_1, [])

      :ok = TestServer.SSH.stop(instance_1)
    end

    test "with invalid options" do
      assert_raise ArgumentError, ~r/expected :all, got: :invalid/, fn ->
        TestServer.SSH.channel(messages: :invalid)
      end

      assert_raise ArgumentError,
                   ~r/expected list to only include \[:exec, :data, :env, :pty, :shell, :eof\], got: \[:invalid\]/,
                   fn ->
                     TestServer.SSH.channel(messages: [:invalid])
                   end
    end

    test "when no channel up message received" do
      defmodule ChannelNoChannelUpMessageTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.channel()

          assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
          assert {:ok, _channel_id} = SSHClient.session_channel(conn)
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "has channels that were not used:"
    end

    test "when receiving unexpected channel up message" do
      defmodule ChannelTooManyChannelUpMessagesTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)

          assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
          assert {:ok, channel_id_1} = SSHClient.session_channel(conn)
          assert {:error, :closed} = SSHClient.exec(conn, channel_id_1, "ping")
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "No channels registered."
      refute io =~ "The following channels were registered:"
    end

    test "when receiving unexpected channel up message after used channels" do
      defmodule ChannelTooManyChannelUpMessagesAfterUsedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)
          TestServer.SSH.handle()

          assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
          assert {:ok, channel_id_1} = SSHClient.session_channel(conn)
          assert {:ok, channel_id_2} = SSHClient.session_channel(conn)
          assert SSHClient.exec(conn, channel_id_1, "ping") == :ok

          assert {:ok, %{data: "ping", exit_status: 0}} =
                   SSHClient.receive_until_closed(conn, channel_id_1)

          assert SSHClient.exec(conn, channel_id_2, "ping") == {:error, :closed}
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      refute io =~ "No channels registered."
      assert io =~ "The following channels were registered:"
    end

    test "with multiple channels" do
      channel_1 = TestServer.SSH.channel()
      channel_2 = TestServer.SSH.channel()

      TestServer.SSH.handle(channel_1, to: fn _data, state -> {:reply, "channel 1", state} end)
      TestServer.SSH.handle(channel_2, to: fn _data, state -> {:reply, "channel 2", state} end)

      assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
      assert {:ok, channel_id_1} = SSHClient.session_channel(conn)
      assert {:ok, channel_id_2} = SSHClient.session_channel(conn)
      assert SSHClient.exec(conn, channel_id_2, "ping") == :ok
      assert SSHClient.exec(conn, channel_id_1, "ping") == :ok

      assert {:ok, %{data: "channel 2", exit_status: 0}} =
               SSHClient.receive_until_closed(conn, channel_id_1)

      assert {:ok, %{data: "channel 1", exit_status: 0}} =
               SSHClient.receive_until_closed(conn, channel_id_2)
    end

    test "with `messages: :all` option" do
      channel = TestServer.SSH.channel(messages: :all)

      TestServer.SSH.handle(channel,
        to: fn {:env, _channel_id, _want_reply, var, value}, state ->
          assert var == "FOO"
          assert value == "bar"

          {:ok, state}
        end
      )

      TestServer.SSH.handle(channel,
        to: fn {:shell, _channel_id, _want_reply}, state ->
          {:ok, state}
        end
      )

      TestServer.SSH.handle(channel,
        to: fn {:pty, _channel_id, _want_reply,
                {
                  terminal,
                  _char_width,
                  _row_height,
                  _pixel_width,
                  _pixel_height,
                  _terminal_modes
                }},
               state ->
          assert terminal == ~c"xterm-256color"

          {:ok, state}
        end
      )

      TestServer.SSH.handle(channel,
        to: fn {:eof, _channel_id}, state ->
          {:ok, state}
        end
      )

      TestServer.SSH.handle(channel,
        to: fn {:data, _channel_id, _want_reply, "ping"}, state ->
          {:reply, "pong", state}
        end
      )

      assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
      assert {:ok, channel_id} = SSHClient.session_channel(conn)
      assert :ssh_connection.setenv(conn, channel_id, ~c"FOO", ~c"bar", 1_000) == :success
      assert {:ok, conn, channel_id} = SSHClient.open_shell(conn, channel_id)
      assert :ssh_connection.ptty_alloc(conn, channel_id, term: ~c"xterm-256color") == :success
      assert :ssh_connection.send_eof(conn, channel_id) == :ok
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert SSHClient.receive_data(conn, channel_id) == {:ok, "pong"}
      assert SSHClient.close(conn, channel_id) == :ok
    end

    test "with `:messages` option" do
      channel = TestServer.SSH.channel(messages: [])

      TestServer.SSH.handle(channel,
        to: fn msg, _state ->
          flunk("Handler should not be called for ignored message: #{inspect(msg)}")
        end
      )

      assert {:ok, conn, channel_id} = ssh_shell()
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert SSHClient.exec(conn, channel_id, "ping") == :ok

      assert {:ok, %{data: nil, exit_status: 0}} =
               SSHClient.receive_until_closed(conn, channel_id)

      assert SSHClient.close(conn, channel_id) == :ok

      TestServer.SSH.stop()
    end
  end

  describe "handle/2" do
    test "with multiple instances" do
      TestServer.SSH.start!()
      TestServer.SSH.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SSH\.handle\/1`/,
                   fn ->
                     TestServer.SSH.handle()
                   end
    end

    test "with multiple channels" do
      TestServer.SSH.channel()
      TestServer.SSH.channel()

      assert_raise RuntimeError,
                   ~r/Multiple channels available, please pass channel to `TestServer\.SSH\.handle\/2`/,
                   fn ->
                     TestServer.SSH.handle()
                   end

      TestServer.SSH.stop()
    end

    test "when connection instance not running" do
      channel = TestServer.SSH.channel()
      :ok = TestServer.SSH.stop()

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     TestServer.SSH.handle(channel)
                   end
    end

    test "with invalid options" do
      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.SSH.handle(to: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.SSH.handle(match: :invalid)
      end

      TestServer.SSH.stop()
    end

    test "when no message received" do
      defmodule HandleNoMessageReceivedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.handle()

          assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
          assert {:ok, _channel_id} = SSHClient.session_channel(conn)
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "did not receive a message for these handlers before the test ended"
    end

    test "when receiving unexpected message" do
      defmodule HandleUnexpectedMessageTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)
          TestServer.SSH.channel()

          assert {:ok, %{data: data, exit_status: 1}} = unquote(__MODULE__).ssh_exec("ping")

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleUnexpectedMessageTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected SSH message"
      assert io =~ "No active handlers."
      refute io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "when receiving unexpected message before all handlers are processed" do
      defmodule HandleUnexpectedMessageBeforeProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)
          TestServer.SSH.handle(match: fn _message, _state -> false end)

          assert {:ok, %{data: data, exit_status: 1}} = unquote(__MODULE__).ssh_exec("ping")

          send(__MODULE__, {:data, data})
          :ok = TestServer.SSH.stop()
        end
      end

      Process.register(self(), HandleUnexpectedMessageBeforeProcessedTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected SSH message"
      assert io =~ "Active handlers:"
      refute io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "when receiving unexpected message after all handlers are processed" do
      defmodule HandleUnexpectedMessageAfterProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)
          TestServer.SSH.handle()

          assert {:ok, conn, channel_id} = unquote(__MODULE__).ssh_shell()
          assert SSHClient.send(conn, channel_id, "first") == :ok
          assert SSHClient.send(conn, channel_id, "second") == :ok
          assert SSHClient.receive_data(conn, channel_id) == {:ok, "first"}
          assert {:ok, data} = SSHClient.receive_data(conn, channel_id)

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleUnexpectedMessageAfterProcessedTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected SSH message"
      assert io =~ "The following handlers have been processed:"
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "with `:to` 3-arity function raising exception" do
      defmodule HandleTo3ArityFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)
          TestServer.SSH.handle(to: fn _msg, _connection, _state -> raise "boom" end)

          assert {:ok, %{data: data, exit_status: 1}} = unquote(__MODULE__).ssh_exec("ping")

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleTo3ArityFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/3 in TestServer.SSHTest.HandleTo3ArityFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "with `:to` 3-arity function with invalid response" do
      defmodule HandleTo3ArityFunctionInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)
          TestServer.SSH.handle(to: fn _msg, _connection, _state -> :invalid end)

          assert {:ok, %{data: data, exit_status: 1}} = unquote(__MODULE__).ssh_exec("ping")

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleTo3ArityFunctionInvalidResponseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "with `:to` 3-arity function returning `{:ok, state}` response" do
      TestServer.SSH.handle(
        to: fn {:data, channel_id, _want_reply, _data}, connection, state ->
          :ssh_connection.adjust_window(connection, channel_id, byte_size("first"))
          :ssh_connection.send(connection, channel_id, "first")
          :ssh_connection.adjust_window(connection, channel_id, byte_size("second"))
          :ssh_connection.send(connection, channel_id, 2, "second")

          {:ok, state}
        end
      )

      assert {:ok, conn, channel_id} = ssh_shell()
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert SSHClient.receive_data(conn, channel_id, 0) == {:ok, "first"}
      assert SSHClient.receive_data(conn, channel_id, 2) == {:ok, "second"}
    end

    test "with `:to` 3-arity function returning `{:stop, channel_id, state}` response" do
      TestServer.SSH.handle(
        to: fn {:exec, channel_id, want_reply, _command}, connection, state ->
          :ssh_connection.reply_request(connection, want_reply, :success, channel_id)
          :ssh_connection.send(connection, channel_id, "first")
          :ssh_connection.send(connection, channel_id, 2, "second")
          :ssh_connection.close(connection, channel_id)

          {:stop, channel_id, state}
        end
      )

      assert {:ok,
              %{
                data: "firstsecond",
                messages: [
                  {:data, 0, 0, "first"},
                  {:data, 0, 2, "second"},
                  {:closed, 0}
                ],
                exit_status: nil
              }} = ssh_exec("ping")
    end

    test "with `:to` 2-arity function raising exception" do
      defmodule HandleTo2ArityFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)
          TestServer.SSH.handle(to: fn _msg, _state -> raise "boom" end)

          assert {:ok, %{data: data, exit_status: 1}} = unquote(__MODULE__).ssh_exec("ping")

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleTo2ArityFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.SSHTest.HandleTo2ArityFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "with `:to` 2-arity function with invalid response" do
      defmodule HandleTo2ArityFunctionInvalidResponseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)
          TestServer.SSH.handle(to: fn _msg, _state -> :invalid end)

          assert {:ok, %{data: data, exit_status: 1}} = unquote(__MODULE__).ssh_exec("ping")

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleTo2ArityFunctionInvalidResponseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "with `:to` 2-arity function with `{:reply, data, state}` response" do
      TestServer.SSH.handle(
        to: fn _msg, state ->
          {:reply, "function called", state}
        end
      )

      assert {:ok, result} = ssh_exec("ping")
      assert result.data == "function called"
      assert result.exit_status == 0

      assert result.messages == [
               {:data, 0, 0, "function called"},
               {:exit_status, 0, 0},
               {:eof, 0},
               {:closed, 0}
             ]
    end

    test "with `:to` 2-arity function with `{:reply, {data, options}, state}` response" do
      test_pid = self()

      TestServer.SSH.handle(
        to: fn _msg, state ->
          # This is to ensure we receive this message before we send close
          send(test_pid, :continue)

          {:reply, {"pong", exit_status: 127, data_type_code: 1}, state}
        end
      )

      assert {:ok, conn, channel_id} = ssh_shell()
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert_receive :continue
      assert SSHClient.close(conn, channel_id) == :ok
      assert {:ok, result} = SSHClient.receive_until_closed(conn, channel_id)
      assert result.data == "pong"
      refute result.exit_status
      assert result.messages == [{:data, 0, 1, "pong"}, {:closed, 0}]

      # Exec handling
      exec_channel = TestServer.SSH.channel()

      TestServer.SSH.handle(exec_channel,
        to: fn _msg, state -> {:reply, {"pong", exit_status: 127, data_type_code: 1}, state} end
      )

      assert {:ok, result} = ssh_exec("ping")
      assert result.data == "pong"
      assert result.exit_status == 127

      assert result.messages == [
               {:data, 0, 1, "pong"},
               {:exit_status, 0, 127},
               {:eof, 0},
               {:closed, 0}
             ]
    end

    test "with `:to` 2-arity function with `{:reply, {data, options}, state}` response with invalid options" do
      defmodule HandleTo2ArityFunctionInvalidOptionsTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)

          TestServer.SSH.handle(
            to: fn _msg, state ->
              {:reply, {"pong", invalid: 1}, state}
            end
          )

          assert {:ok, %{data: data, exit_status: 1}} = unquote(__MODULE__).ssh_exec("ping")

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), HandleTo2ArityFunctionInvalidOptionsTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) Invalid options in callback response, got: [invalid: 1]."
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "with `:to` 2-arity function with `{:ok, state}` response" do
      TestServer.SSH.start!()
      TestServer.SSH.handle(to: fn _msg, state -> {:ok, Map.put(state, :key, "value")} end)
      TestServer.SSH.handle(to: fn _msg, state -> {:reply, Map.fetch!(state, :key), state} end)

      assert {:ok, conn, channel_id} = ssh_shell()
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert SSHClient.receive_data(conn, channel_id) == {:ok, "value"}
    end

    test "when `:match` function raises exception" do
      defmodule MatchFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SSH.start!(suppress_warning: true)

          TestServer.SSH.handle(
            match: fn {:exec, _channel_id, _want_reply, _command}, _state ->
              raise "boom"
            end
          )

          assert {:ok, %{data: data, exit_status: 1}} = unquote(__MODULE__).ssh_exec("ping")

          send(__MODULE__, {:data, data})
        end
      end

      Process.register(self(), MatchFunctionRaiseTest)

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/2 in TestServer.SSHTest.MatchFunctionRaiseTest"
      assert_receive {:data, data}
      assert_io_ssh_data(io, data)
    end

    test "with `:match` function" do
      TestServer.SSH.handle(
        match: fn {:data, _channel_id, _type, data}, _state -> data == "pong" end,
        to: fn _frame, state -> {:reply, "1", state} end
      )

      TestServer.SSH.handle(to: fn _frame, state -> {:reply, "2", state} end)

      assert {:ok, conn, channel_id} = ssh_shell()
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert SSHClient.receive_data(conn, channel_id) == {:ok, "2"}
      assert SSHClient.send(conn, channel_id, "pong") == :ok
      assert SSHClient.receive_data(conn, channel_id) == {:ok, "1"}
    end
  end

  describe "host_keys/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.SSH.Instance running", fn ->
        TestServer.SSH.host_keys()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.SSH.start!()
                     :ok = TestServer.SSH.stop()

                     TestServer.SSH.host_keys(instance)
                   end
    end

    test "when instance running with `:host_keys` function" do
      TestServer.SSH.start(
        host_keys: fn _algorithm, _daemon_options ->
          {:ok, :public_key.generate_key({:rsa, 2_048, 65_537})}
        end
      )

      assert_raise RuntimeError,
                   ~r/TestServer\.SSH\.Instance \#PID\<[0-9.]+\> is running with `\[host_keys: function\]` option/,
                   fn ->
                     TestServer.SSH.host_keys()
                   end
    end
  end

  def ssh_exec(command) do
    assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
    assert {:ok, channel_id} = SSHClient.session_channel(conn)
    assert SSHClient.exec(conn, channel_id, command) == :ok

    SSHClient.receive_until_closed(conn, channel_id)
  end

  def ssh_shell do
    assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
    assert {:ok, channel_id} = SSHClient.session_channel(conn)

    SSHClient.open_shell(conn, channel_id)
  end

  defmodule SSHClient do
    def write_user_dir_pem!(key, base_name, path) do
      type = elem(key, 0)
      pem_entry = :public_key.pem_entry_encode(type, key)
      pem = :public_key.pem_encode([pem_entry])
      File.write!(Path.join(path, "#{base_name}"), pem)

      path
    end

    def sockname(conn) do
      {:sockname, res} = :ssh.connection_info(conn, :sockname)

      res
    end

    def connect({host, port}, options \\ []) do
      options =
        [
          silently_accept_hosts: true,
          user_interaction: false
        ]
        |> Keyword.merge(options)
        |> normalize_ssh_connect_options()

      :logger.add_primary_filter(
        :suppress_ssh_log_messages,
        {fn
           %{level: :debug, msg: {:string, ~c"client will use strict KEX ordering"}}, _extra ->
             :stop

           %{level: :notice, msg: {:report, %{report: msg}}}, _extra ->
             (to_string(msg) =~ "Ssh login attempt to" && :stop) || :ignore

           _event, _extra ->
             :ignore
         end, []}
      )

      host
      |> to_charlist()
      |> :ssh.connect(port, options)
      |> handle_resp()
      |> case do
        {:ok, conn} ->
          on_exit(fn -> close(conn) end)

          {:ok, conn}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp normalize_ssh_connect_options(options) do
      Enum.reduce(~w(user password auth_methods user_dir)a, options, fn key, options ->
        case Keyword.has_key?(options, key) do
          true -> Keyword.update!(options, key, &String.to_charlist/1)
          false -> options
        end
      end)
    end

    defp handle_resp({:ok, conn}), do: {:ok, conn}
    defp handle_resp({:error, reason}) when is_list(reason), do: {:error, to_string(reason)}
    defp handle_resp({:error, reason}), do: {:error, reason}

    def open_shell(conn, channel_id) do
      case :ssh_connection.shell(conn, channel_id) do
        :ok -> {:ok, conn, channel_id}
        :failure -> {:error, :failure}
        {:error, :timeout} -> {:error, :timeout}
      end
    end

    def session_channel(conn, timeout \\ 500) do
      conn
      |> :ssh_connection.session_channel(timeout)
      |> handle_resp()
    end

    def send(conn, channel_id, data) do
      case :ssh_connection.send(conn, channel_id, data) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    def exec(conn, channel_id, command, timeout \\ 500) do
      case :ssh_connection.exec(conn, channel_id, command, timeout) do
        :success -> :ok
        :failure -> {:error, :failure}
        {:error, reason} -> {:error, reason}
      end
    end

    def receive_until_closed(
          conn,
          channel_id,
          state \\ %{data: nil, exit_status: nil, messages: []}
        ) do
      receive do
        {:ssh_cm, ^conn, {:exit_status, ^channel_id, status} = msg} ->
          receive_until_closed(conn, channel_id, %{
            state
            | exit_status: status,
              messages: state.messages ++ [msg]
          })

        {:ssh_cm, ^conn, {:data, ^channel_id, _want_reply, data} = msg} ->
          data = (state.data || "") <> data

          receive_until_closed(conn, channel_id, %{
            state
            | data: data,
              messages: state.messages ++ [msg]
          })

        {:ssh_cm, ^conn, {:eof, ^channel_id} = msg} ->
          receive_until_closed(conn, channel_id, %{state | messages: state.messages ++ [msg]})

        {:ssh_cm, ^conn, {:closed, ^channel_id} = msg} ->
          {:ok, %{state | messages: state.messages ++ [msg]}}
      after
        500 -> {:error, :timeout}
      end
    end

    def receive_data(conn, channel_id, type \\ 0) do
      assert_receive {:ssh_cm, ^conn, {:data, ^channel_id, ^type, data}}

      {:ok, to_string(data)}
    end

    def close(conn) do
      :ssh.close(conn)
    end

    def close(conn, channel_id) do
      :ssh_connection.close(conn, channel_id)
    end
  end

  defp assert_io_ssh_data(io, message) do
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
