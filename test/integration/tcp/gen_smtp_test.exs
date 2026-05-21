defmodule TestServer.TCP.GenSMTPTest do
  use ExUnit.Case

  # Remove when Elixir 1.18 is required
  if Version.match?(System.version(), "< 1.18.0") do
    setup do
      {:ok, test_pid: self()}
    end
  end

  test ":gen_smtp_client.send_blocking/2", %{test_pid: test_pid} do
    message =
      """
      From: from@example.com
      To: to@example.com
      Subject: Hello
      Content-Type: text/plain; charset=utf-8

      Hello from :gen_smtp!
      """

    TestServer.TCP.start!(listen: [packet: :line], transport: [:tcp, :tls])

    connection = TestServer.TCP.connection()

    # Advertise STARTTLS
    TestServer.TCP.handle(connection,
      to: fn data, state ->
        assert "EHLO " <> _ = data

        {:reply, "250-localhost\r\n250 STARTTLS\r\n", state}
      end
    )

    # Upgrade the existing connection
    TestServer.TCP.handle(connection,
      to: fn data, state ->
        assert data == "STARTTLS\r\n"

        {:reply, {"220 Ready to start TLS\r\n", upgrade: :tls}, state}
      end
    )

    # The SMTP client sends EHLO again after upgrading
    TestServer.TCP.handle(connection,
      to: fn data, state ->
        assert "EHLO " <> _ = data

        {:reply, "250 localhost\r\n", state}
      end
    )

    # MAIL FROM command
    TestServer.TCP.handle(connection,
      to: fn data, state ->
        assert data == "MAIL FROM:<from@example.com>\r\n"

        {:reply, "250 OK\r\n", state}
      end
    )

    # RCPT TO command
    TestServer.TCP.handle(connection,
      to: fn data, state ->
        assert data == "RCPT TO:<to@example.com>\r\n"

        {:reply, "250 OK\r\n", state}
      end
    )

    # DATA command
    TestServer.TCP.handle(connection,
      to: fn data, state ->
        assert data == "DATA\r\n"

        {:reply, "354 End data with <CR><LF>.<CR><LF>\r\n", Map.put(state, :email, "")}
      end
    )

    # Email content line by line
    Enum.each(0..7, fn _ ->
      TestServer.TCP.handle(connection,
        to: fn
          "." <> _, state ->
            assert state.email == message <> "\r\n"

            {:reply, "250 OK\r\n", state}

          data, state ->
            {:ok, %{state | email: state.email <> data}}
        end
      )
    end)

    # QUIT command
    TestServer.TCP.handle(connection,
      to: fn data, state ->
        assert data =~ "QUIT"

        send(test_pid, :smtp_quit)

        {:ok, state}
      end
    )

    {host, port} = TestServer.TCP.address()

    # Send greeting as soon as the socket is established
    Task.start(fn ->
      TestServer.TCP.send(connection,
        to: fn state -> {:reply, "220 localhost ESMTP\r\n", state} end
      )
    end)

    options = [
      relay: String.to_charlist(host),
      port: port,
      tls: :always,
      tls_options: [
        verify: :verify_peer,
        cacerts: TestServer.TCP.cacerts(),
        depth: 1,
        server_name_indication: String.to_charlist(host),
        log_level: :warning
      ],
      auth: :never,
      no_mx_lookups: true
    ]

    assert :gen_smtp_client.send_blocking(
             {~c"from@example.com", [~c"to@example.com"], message},
             options
           ) == "OK\r\n"

    # :gen_smtp_client doesn't wait for the QUIT response so we want to ensure
    # we received the QUIT command before ending the test
    assert_receive :smtp_quit
  end
end
