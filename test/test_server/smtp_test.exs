defmodule TestServer.SMTPTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias TestServer.SMTPClient

  describe "start/1" do
    test "with invalid port" do
      assert_raise RuntimeError, ~r/Invalid port, got: :invalid/, fn ->
        TestServer.SMTP.start(port: :invalid)
      end

      assert_raise RuntimeError, ~r/Invalid port, got: 65536/, fn ->
        TestServer.SMTP.start(port: 65_536)
      end

      assert_raise RuntimeError, ~r/Could not listen to port 2525, because: :eaddrinuse/, fn ->
        TestServer.SMTP.start(port: 2525)
        TestServer.SMTP.start(port: 2525)
      end
    end

    test "starts with multiple ports" do
      {:ok, instance_1} = TestServer.SMTP.start()
      {:ok, instance_2} = TestServer.SMTP.start()

      refute instance_1 == instance_2

      {"localhost", port_1} = TestServer.SMTP.address(instance_1)
      {"localhost", port_2} = TestServer.SMTP.address(instance_2)

      refute port_1 == port_2
    end

    test "starts with TLS" do
      {:ok, _instance} = TestServer.SMTP.start(tls: true)
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, extensions, client} = SMTPClient.ehlo(client)
      extension_names = Enum.map(extensions, fn {_code, ext} -> ext end)
      assert Enum.any?(extension_names, &String.contains?(&1, "STARTTLS"))
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "starts with TLS and sends email" do
      {:ok, instance} = TestServer.SMTP.start(tls: true)
      TestServer.SMTP.add(instance)

      assert :ok =
               smtp_send!(instance,
                 from: "a@b.com",
                 to: "c@d.com",
                 body: "tls test",
                 tls: true
               )
    end

    test "starts without TLS" do
      {:ok, _instance} = TestServer.SMTP.start()
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, extensions, client} = SMTPClient.ehlo(client)
      extension_names = Enum.map(extensions, fn {_code, ext} -> ext end)
      refute Enum.any?(extension_names, &String.contains?(&1, "STARTTLS"))
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "starts without credentials" do
      {:ok, _instance} = TestServer.SMTP.start()
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, extensions, client} = SMTPClient.ehlo(client)
      extension_names = Enum.map(extensions, fn {_code, ext} -> ext end)
      refute Enum.any?(extension_names, &String.contains?(&1, "AUTH"))
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "starts with credentials" do
      {:ok, _instance} = TestServer.SMTP.start(credentials: [{"user", "pass"}])
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, extensions, client} = SMTPClient.ehlo(client)
      extension_names = Enum.map(extensions, fn {_code, ext} -> ext end)
      assert Enum.any?(extension_names, &String.contains?(&1, "AUTH"))
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "starts with AUTH PLAIN credentials" do
      {:ok, instance} = TestServer.SMTP.start(credentials: [{"alice", "secret"}])
      TestServer.SMTP.add(instance)

      assert :ok =
               smtp_send!(instance,
                 from: "a@b.com",
                 to: "c@d.com",
                 body: "auth test",
                 auth: {"alice", "secret"}
               )
    end

    test "starts with AUTH PLAIN rejects wrong password" do
      {:ok, _instance} = TestServer.SMTP.start(credentials: [{"alice", "secret"}])
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, client} = SMTPClient.auth_plain(client, "alice", "wrong")
      assert response =~ "535"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "starts with AUTH LOGIN credentials" do
      {:ok, instance} = TestServer.SMTP.start(credentials: [{"bob", "password"}])
      TestServer.SMTP.add(instance)

      port = TestServer.SMTP.port(instance)
      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, client} = SMTPClient.auth_login(client, "bob", "password")
      assert response =~ "235"

      {:ok, _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, _, client} = SMTPClient.data(client, "Subject: Login test\r\n\r\nBody")

      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "starts with AUTH LOGIN rejects wrong password" do
      {:ok, _instance} = TestServer.SMTP.start(credentials: [{"bob", "password"}])
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, client} = SMTPClient.auth_login(client, "bob", "wrong")
      assert response =~ "535"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "starts with credentials populates email auth" do
      {:ok, instance} = TestServer.SMTP.start(credentials: [{"alice", "secret"}])
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email ->
          send(test_pid, {:auth, email.auth})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "a@b.com",
          to: "c@d.com",
          body: "auth test",
          auth: {"alice", "secret"}
        )

      assert_receive {:auth, {"alice", "secret"}}
    end
  end

  describe "stop/1" do
    test "when not running" do
      assert_raise RuntimeError, "No current TestServer.SMTP.Instance running", fn ->
        TestServer.SMTP.stop()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.SMTP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     {:ok, instance} = TestServer.SMTP.start()

                     assert :ok = TestServer.SMTP.stop()

                     TestServer.SMTP.stop(instance)
                   end
    end

    test "stops" do
      {:ok, pid} = TestServer.SMTP.start()

      assert :ok = TestServer.SMTP.stop()
      refute Process.alive?(pid)
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.SMTP.start()
      {:ok, _instance_2} = TestServer.SMTP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SMTP\.stop\/0`/,
                   fn ->
                     TestServer.SMTP.stop()
                   end

      assert :ok = TestServer.SMTP.stop(instance_1)
      assert :ok = TestServer.SMTP.stop()
    end
  end

  describe "address/1" do
    test "when not running" do
      assert_raise RuntimeError, "No current TestServer.SMTP.Instance running", fn ->
        TestServer.SMTP.address()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.SMTP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     {:ok, instance} = TestServer.SMTP.start()

                     assert :ok = TestServer.SMTP.stop()

                     TestServer.SMTP.address(instance)
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.SMTP.start()
      {:ok, instance_2} = TestServer.SMTP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.SMTP\.address\/0`/,
                   fn ->
                     TestServer.SMTP.address()
                   end

      refute TestServer.SMTP.address(instance_1) == TestServer.SMTP.address(instance_2)
    end

    test "produces address" do
      {:ok, _instance} = TestServer.SMTP.start()

      assert {"localhost", port} = TestServer.SMTP.address()
      assert is_integer(port)
      assert port > 0
    end
  end

  describe "add/2" do
    test "when instance not running" do
      assert_raise RuntimeError,
                   ~r/TestServer\.SMTP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     {:ok, instance} = TestServer.SMTP.start()

                     assert :ok = TestServer.SMTP.stop()

                     TestServer.SMTP.add(instance)
                   end
    end

    test "with invalid options" do
      {:ok, instance} = TestServer.SMTP.start()

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.SMTP.add(instance, match: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.SMTP.add(instance, to: :invalid)
      end

      assert_raise BadFunctionError, fn ->
        TestServer.SMTP.add(instance, match: ~r/test/)
      end
    end

    test "with default handler" do
      {:ok, instance} = TestServer.SMTP.start()
      TestServer.SMTP.add(instance)

      assert :ok =
               smtp_send!(instance,
                 from: "sender@example.com",
                 to: "recipient@example.com",
                 subject: "Hello",
                 body: "World"
               )
    end

    test "with callback function" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email ->
          send(test_pid, {:email, email})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "sender@example.com",
          to: "recipient@example.com",
          subject: "Test Subject",
          body: "Test Body"
        )

      assert_receive {:email, email}
      assert email.mail_from == "sender@example.com"
      assert "recipient@example.com" in email.rcpt_to
      assert email.subject == "Test Subject"
      assert email.body =~ "Test Body"
    end

    test "with match function" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        match: fn email -> email.mail_from == "wanted@example.com" end,
        to: fn email ->
          send(test_pid, {:matched, email.mail_from})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "wanted@example.com",
          to: "to@example.com",
          body: "test"
        )

      assert_receive {:matched, "wanted@example.com"}
    end

    test "with match on header field" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        match: fn email -> email.subject == "Special" end,
        to: fn email ->
          send(test_pid, {:matched, email.subject})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "a@b.com",
          to: "c@d.com",
          subject: "Special",
          body: "test"
        )

      assert_receive {:matched, "Special"}
    end

    test "with multiple handlers" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn _email ->
          send(test_pid, :first)
          :ok
        end
      )

      TestServer.SMTP.add(instance,
        to: fn _email ->
          send(test_pid, :second)
          :ok
        end
      )

      :ok = smtp_send!(instance, from: "a@b.com", to: "c@d.com", body: "1")
      :ok = smtp_send!(instance, from: "a@b.com", to: "c@d.com", body: "2")

      assert_receive :first
      assert_receive :second
    end

    test "with match filtering" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        match: fn email -> email.mail_from == "skip@example.com" end,
        to: fn _email ->
          send(test_pid, :wrong)
          :ok
        end
      )

      TestServer.SMTP.add(instance,
        match: fn email -> email.mail_from == "target@example.com" end,
        to: fn _email ->
          send(test_pid, :right)
          :ok
        end
      )

      :ok = smtp_send!(instance, from: "target@example.com", to: "c@d.com", body: "test")

      assert_receive :right
      refute_receive :wrong

      # Consume remaining handler
      :ok = smtp_send!(instance, from: "skip@example.com", to: "c@d.com", body: "test")

      assert_receive :wrong
    end

    test "with `:ok` response" do
      {:ok, instance} = TestServer.SMTP.start()

      TestServer.SMTP.add(instance, to: fn _email -> :ok end)

      port = TestServer.SMTP.port(instance)
      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, "250" <> _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, "250" <> _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, response, client} = SMTPClient.data(client, "Subject: Test\r\n\r\nBody")
      assert response =~ "250"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "with `{:ok, message}` response" do
      {:ok, instance} = TestServer.SMTP.start()

      TestServer.SMTP.add(instance,
        to: fn _email -> {:ok, "250 2.0.0 Queued as ABC123"} end
      )

      port = TestServer.SMTP.port(instance)
      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, response, client} = SMTPClient.data(client, "Subject: Test\r\n\r\nBody")
      assert response =~ "Queued as ABC123"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "with `:error` response" do
      {:ok, instance} = TestServer.SMTP.start(suppress_warning: true)

      TestServer.SMTP.add(instance, to: fn _email -> :error end)

      port = TestServer.SMTP.port(instance)
      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, response, client} = SMTPClient.data(client, "Subject: Test\r\n\r\nBody")
      assert response =~ "550"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "with `{:error, message}` response" do
      {:ok, instance} = TestServer.SMTP.start(suppress_warning: true)

      TestServer.SMTP.add(instance,
        to: fn _email -> {:error, "451 4.7.1 Try again later"} end
      )

      port = TestServer.SMTP.port(instance)
      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, response, client} = SMTPClient.data(client, "Subject: Test\r\n\r\nBody")
      assert response =~ "451"
      assert response =~ "Try again later"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "with callback function raising exception" do
      defmodule CallbackRaiseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} = TestServer.SMTP.start(suppress_warning: true)

          TestServer.SMTP.add(instance, to: fn _email -> raise "boom" end)

          unquote(__MODULE__).smtp_send(instance,
            from: "a@b.com",
            to: "c@d.com",
            body: "test"
          )
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "(RuntimeError) boom"
    end

    test "with invalid callback response" do
      defmodule InvalidCallbackResponseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} = TestServer.SMTP.start(suppress_warning: true)

          TestServer.SMTP.add(instance, to: fn _email -> :invalid end)

          unquote(__MODULE__).smtp_send(instance,
            from: "a@b.com",
            to: "c@d.com",
            body: "test"
          )
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "Invalid callback response, got: :invalid."
    end

    test "with no email received" do
      defmodule NoEmailReceivedTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} = TestServer.SMTP.start()

          TestServer.SMTP.add(instance,
            match: fn email -> email.mail_from == "expected@example.com" end,
            to: fn _email -> :ok end
          )
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "did not receive expected emails"
    end

    test "when receiving unexpected email" do
      defmodule UnexpectedEmailTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} = TestServer.SMTP.start(suppress_warning: true)

          unquote(__MODULE__).smtp_send(instance,
            from: "surprise@example.com",
            to: "c@d.com",
            body: "unexpected"
          )
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "received an unexpected SMTP email"
    end

    test "with multiple recipients" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email ->
          send(test_pid, {:rcpts, email.rcpt_to})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "sender@example.com",
          to: ["r1@example.com", "r2@example.com"],
          body: "multi"
        )

      assert_receive {:rcpts, rcpts}
      assert "r1@example.com" in rcpts
      assert "r2@example.com" in rcpts
    end

    test "with connection reuse" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn _email ->
          send(test_pid, :email_1)
          :ok
        end
      )

      TestServer.SMTP.add(instance,
        to: fn _email ->
          send(test_pid, :email_2)
          :ok
        end
      )

      port = TestServer.SMTP.port(instance)
      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)

      # First email
      {:ok, _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, _, client} = SMTPClient.data(client, "Subject: First\r\n\r\nBody 1")
      assert_receive :email_1

      # Second email on same connection
      {:ok, _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, _, client} = SMTPClient.data(client, "Subject: Second\r\n\r\nBody 2")
      assert_receive :email_2

      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "with RSET" do
      {:ok, instance} = TestServer.SMTP.start()
      TestServer.SMTP.add(instance)

      port = TestServer.SMTP.port(instance)
      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)

      {:ok, _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, response, client} = SMTPClient.rset(client)
      assert response =~ "250"

      # Can start new transaction
      {:ok, _, client} = SMTPClient.mail_from(client, "new@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, _, client} = SMTPClient.data(client, "Subject: After RSET\r\n\r\nBody")

      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "with QUIT" do
      {:ok, _instance} = TestServer.SMTP.start()
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, _client} = SMTPClient.quit(client)
      assert response =~ "221"
    end

    test "with unrecognized command" do
      {:ok, _instance} = TestServer.SMTP.start()
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, client} = SMTPClient.send_command(client, "BOGUS")
      assert response =~ "500"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "with HELO" do
      {:ok, instance} = TestServer.SMTP.start()
      TestServer.SMTP.add(instance)

      port = TestServer.SMTP.port(instance)
      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, response, client} = SMTPClient.helo(client)
      assert response =~ "250"

      {:ok, _, client} = SMTPClient.mail_from(client, "a@b.com")
      {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
      {:ok, _, client} = SMTPClient.data(client, "Subject: HELO test\r\n\r\nBody")

      SMTPClient.quit(client)
      SMTPClient.close(client)
    end
  end

  describe "email struct" do
    test "with envelope addresses" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email ->
          send(test_pid, {:email, email})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "envelope-from@example.com",
          to: ["recip1@example.com", "recip2@example.com"],
          body: "multi"
        )

      assert_receive {:email, email}
      assert email.mail_from == "envelope-from@example.com"
      assert "recip1@example.com" in email.rcpt_to
      assert "recip2@example.com" in email.rcpt_to
    end

    test "with parsed headers" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email ->
          send(test_pid, {:email, email})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "from@example.com",
          to: "to@example.com",
          subject: "Test Subject",
          body: "Body text"
        )

      assert_receive {:email, email}
      assert email.subject == "Test Subject"
      assert email.from =~ "from@example.com"
      assert email.to =~ "to@example.com"
    end

    test "with body" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email ->
          send(test_pid, {:email, email})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "a@b.com",
          to: "c@d.com",
          subject: "Subject",
          body: "Hello plain text"
        )

      assert_receive {:email, email}
      assert email.body =~ "Hello plain text"
    end

    test "with raw payload" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email ->
          send(test_pid, {:email, email})
          :ok
        end
      )

      :ok =
        smtp_send!(instance,
          from: "a@b.com",
          to: "c@d.com",
          body: "raw content"
        )

      assert_receive {:email, email}
      assert is_binary(email.raw)
      assert email.raw =~ "raw content"
    end
  end

  def smtp_send!(instance, opts) do
    port = TestServer.SMTP.port(instance)
    SMTPClient.send_email("localhost", port, opts)
  end

  def smtp_send(instance, opts) do
    port = TestServer.SMTP.port(instance)
    SMTPClient.send_email("localhost", port, opts)
  rescue
    error -> {:error, error}
  end
end
