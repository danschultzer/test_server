defmodule TestServer.Integration.SSH.SSHKitTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    suppress_ssh_strict_kex_ordering_log()
    TestServer.SSH.start!(user_passwords: [{"deploy", "test-password"}])

    fingerprints = Enum.map(TestServer.SSH.host_keys(), & &1.fingerprint)
    {host, port} = TestServer.SSH.address()

    options = [
      port: port,
      user: "deploy",
      password: "test-password",
      auth_methods: "password",
      user_dir: tmp_dir,
      silently_accept_hosts: fn _peer, fingerprint -> fingerprint in fingerprints end,
      user_interaction: false
    ]

    %{host: host, options: options}
  end

  test "SSHKit.run/2", %{host: host, options: options} do
    TestServer.SSH.handle(
      to: fn {:exec, _channel_id, _want_reply, command}, state ->
        assert to_string(command) == "/usr/bin/env echo \"Hello World!\""

        {:reply, "Hello World!\n", state}
      end
    )

    [{:ok, output, 0}] =
      {host, options}
      |> SSHKit.context()
      |> SSHKit.run("echo \"Hello World!\"")

    stdout =
      output
      |> Keyword.get_values(:stdout)
      |> Enum.join()

    assert "Hello World!\n" == stdout
  end

  test "SSHKit.upload/3", %{tmp_dir: tmp_dir, host: host, options: options} do
    source = Path.join(tmp_dir, "fixtures")
    File.mkdir!(source)
    File.write!(Path.join(source, "hello.txt"), "Hello World!\n")

    channel = TestServer.SSH.channel(messages: [:exec, :data, :eof])

    TestServer.SSH.handle(channel,
      to: fn {:exec, _channel_id, _want_reply, command}, state ->
        assert to_string(command) == "cd /workspace && /usr/bin/env scp -t -r ."

        {:reply, {<<0>>, close: false}, state}
      end
    )

    TestServer.SSH.handle(channel,
      to: fn {:data, _channel_id, 0, data}, state ->
        assert data =~ ~r/^D[0-7]{4} 0 fixtures\n$/

        {:reply, <<0>>, state}
      end
    )

    TestServer.SSH.handle(channel,
      to: fn {:data, _channel_id, 0, data}, state ->
        assert data =~ ~r/^C[0-7]{4} 13 hello\.txt\n$/

        {:reply, <<0>>, state}
      end
    )

    TestServer.SSH.handle(channel,
      to: fn {:data, _channel_id, 0, data}, state ->
        assert data == "Hello World!\n"

        {:ok, state}
      end
    )

    TestServer.SSH.handle(channel,
      to: fn {:data, _channel_id, 0, data}, state ->
        assert data == <<0>>

        {:reply, <<0>>, state}
      end
    )

    TestServer.SSH.handle(channel,
      to: fn {:data, _channel_id, 0, data}, state ->
        assert data == "E\n"

        {:reply, <<0>>, state}
      end
    )

    TestServer.SSH.handle(channel,
      to: fn {:eof, _channel_id}, state ->
        {:ok, [close: true], state}
      end
    )

    # SSHKit uses a deprecated File.stream! call
    assert capture_io(:stderr, fn ->
             assert [:ok] =
                      {host, options}
                      |> SSHKit.context()
                      |> SSHKit.path("/workspace")
                      |> SSHKit.upload(source, as: ".", recursive: true, timeout: 5_000)
           end) =~
             ((Version.match?(System.version(), ">= 1.20.0") &&
                 "File.stream!(path, modes, line_or_byte) is deprecated") || "")
  end

  test "SSHKit.download/3", %{tmp_dir: tmp_dir, host: host, options: options} do
    target = Path.join(tmp_dir, "downloads")
    channel = TestServer.SSH.channel()

    TestServer.SSH.handle(channel,
      to: fn {:exec, _channel_id, _want_reply, command}, state ->
        assert to_string(command) == "cd /workspace && /usr/bin/env scp -f -r ."

        {:ok, [close: false], state}
      end
    )

    for data <- ["D0755 0 fixtures\n", "C0644 13 hello.txt\n", "Hello World!\n\0", "E\n"] do
      TestServer.SSH.handle(channel,
        to: fn {:data, _channel_id, 0, ack}, state ->
          assert ack == <<0>>

          {:reply, data, state}
        end
      )
    end

    TestServer.SSH.handle(channel,
      to: fn {:data, _channel_id, 0, ack}, state ->
        assert ack == <<0>>

        {:ok, [close: true], state}
      end
    )

    assert [:ok] =
             {host, options}
             |> SSHKit.context()
             |> SSHKit.path("/workspace")
             |> SSHKit.download(".", as: target, recursive: true, timeout: 5_000)

    assert File.read!(Path.join(target, "hello.txt")) == "Hello World!\n"
  end

  defp suppress_ssh_strict_kex_ordering_log do
    :logger.add_primary_filter(
      __MODULE__,
      {fn
         %{level: :debug, msg: {:string, ~c"client will use strict KEX ordering"}}, _extra ->
           :stop

         _event, _extra ->
           :ignore
       end, []}
    )

    on_exit(fn ->
      :logger.remove_primary_filter(__MODULE__)
    end)
  end
end
