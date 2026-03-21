defmodule TestServer.SMTPTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias TestServer.SMTPClient

  describe "add/2" do
    test "default handler accepts email" do
      {:ok, instance} = TestServer.SMTP.start()
      TestServer.SMTP.add(instance)

      port = TestServer.SMTP.port(instance)

      assert :ok =
               SMTPClient.send_email("localhost", port,
                 from: "sender@example.com",
                 to: "recipient@example.com",
                 subject: "Hello",
                 body: "World"
               )
    end

    test "custom handler receives email struct" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
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
  end

  describe "add/2 with match" do
    test "match filters which handler runs" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        match: fn email, _state -> email.mail_from == "wanted@example.com" end,
        to: fn email, state ->
          send(test_pid, {:matched, email.mail_from})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "wanted@example.com",
          to: "to@example.com",
          body: "test"
        )

      assert_receive {:matched, "wanted@example.com"}
    end

    test "match on subject" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        match: fn email, _state -> email.subject == "Special" end,
        to: fn email, state ->
          send(test_pid, {:matched, email.subject})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "a@b.com",
          to: "c@d.com",
          subject: "Special",
          body: "test"
        )

      assert_receive {:matched, "Special"}
    end
  end

  describe "handler ordering" do
    test "FIFO consumption — handlers consumed in registration order" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn _email, state ->
          send(test_pid, :first)
          {:ok, state}
        end
      )

      TestServer.SMTP.add(instance,
        to: fn _email, state ->
          send(test_pid, :second)
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "a@b.com",
          to: "c@d.com",
          body: "1"
        )

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "a@b.com",
          to: "c@d.com",
          body: "2"
        )

      assert_receive :first
      assert_receive :second
    end

    test "match filtering skips non-matching handlers" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        match: fn email, _state -> email.mail_from == "skip@example.com" end,
        to: fn _email, state ->
          send(test_pid, :wrong)
          {:ok, state}
        end
      )

      TestServer.SMTP.add(instance,
        match: fn email, _state -> email.mail_from == "target@example.com" end,
        to: fn _email, state ->
          send(test_pid, :right)
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "target@example.com",
          to: "c@d.com",
          body: "test"
        )

      assert_receive :right
      refute_receive :wrong

      # Consume remaining handler
      :ok =
        SMTPClient.send_email("localhost", port,
          from: "skip@example.com",
          to: "c@d.com",
          body: "test"
        )

      assert_receive :wrong
    end
  end

  describe "response format" do
    test "{:ok, state} sends 250 response" do
      {:ok, instance} = TestServer.SMTP.start()

      TestServer.SMTP.add(instance,
        to: fn _email, state -> {:ok, state} end
      )

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

    test "{:ok, custom_msg, state} sends custom 250 response" do
      {:ok, instance} = TestServer.SMTP.start()

      TestServer.SMTP.add(instance,
        to: fn _email, state -> {:ok, "250 2.0.0 Queued as ABC123", state} end
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

    test "{:error, state} sends 550 response" do
      {:ok, instance} = TestServer.SMTP.start(suppress_warning: true)

      TestServer.SMTP.add(instance,
        to: fn _email, state -> {:error, state} end
      )

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

    test "{:error, custom_msg, state} sends custom error response" do
      {:ok, instance} = TestServer.SMTP.start(suppress_warning: true)

      TestServer.SMTP.add(instance,
        to: fn _email, state -> {:error, "451 4.7.1 Try again later", state} end
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
  end

  describe "SMTP protocol" do
    test "multiple recipients" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email, state ->
          send(test_pid, {:rcpts, email.rcpt_to})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "sender@example.com",
          to: ["r1@example.com", "r2@example.com"],
          body: "multi"
        )

      assert_receive {:rcpts, rcpts}
      assert "r1@example.com" in rcpts
      assert "r2@example.com" in rcpts
    end

    test "multiple emails per connection" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn _email, state ->
          send(test_pid, :email_1)
          {:ok, state}
        end
      )

      TestServer.SMTP.add(instance,
        to: fn _email, state ->
          send(test_pid, :email_2)
          {:ok, state}
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

    test "RSET resets transaction" do
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

    test "QUIT sends 221" do
      {:ok, _instance} = TestServer.SMTP.start()
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, _client} = SMTPClient.quit(client)
      assert response =~ "221"
    end

    test "unrecognized command returns 500" do
      {:ok, _instance} = TestServer.SMTP.start()
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, client} = SMTPClient.send_command(client, "BOGUS")
      assert response =~ "500"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "HELO works as alternative to EHLO" do
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
    test "mail_from and rcpt_to from envelope" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "envelope-from@example.com",
          to: ["recip1@example.com", "recip2@example.com"],
          body: "multi"
        )

      assert_receive {:email, email}
      assert email.mail_from == "envelope-from@example.com"
      assert "recip1@example.com" in email.rcpt_to
      assert "recip2@example.com" in email.rcpt_to
    end

    test "headers parsed from message" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
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

    test "body extracted from after headers" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "a@b.com",
          to: "c@d.com",
          subject: "Subject",
          body: "Hello plain text"
        )

      assert_receive {:email, email}
      assert email.body =~ "Hello plain text"
    end

    test "raw field contains full DATA payload" do
      {:ok, instance} = TestServer.SMTP.start()
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "a@b.com",
          to: "c@d.com",
          body: "raw content"
        )

      assert_receive {:email, email}
      assert is_binary(email.raw)
      assert email.raw =~ "raw content"
    end
  end

  describe "STARTTLS" do
    test "EHLO advertises STARTTLS when tls enabled" do
      {:ok, _instance} = TestServer.SMTP.start(tls: true)
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, extensions, client} = SMTPClient.ehlo(client)
      extension_names = Enum.map(extensions, fn {_code, ext} -> ext end)
      assert Enum.any?(extension_names, &String.contains?(&1, "STARTTLS"))
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "STARTTLS upgrade works" do
      {:ok, instance} = TestServer.SMTP.start(tls: true)
      TestServer.SMTP.add(instance)

      port = TestServer.SMTP.port(instance)

      assert :ok =
               SMTPClient.send_email("localhost", port,
                 from: "a@b.com",
                 to: "c@d.com",
                 body: "tls test",
                 tls: true
               )
    end

    test "EHLO does not advertise STARTTLS when tls disabled" do
      {:ok, _instance} = TestServer.SMTP.start()
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, extensions, client} = SMTPClient.ehlo(client)
      extension_names = Enum.map(extensions, fn {_code, ext} -> ext end)
      refute Enum.any?(extension_names, &String.contains?(&1, "STARTTLS"))
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end
  end

  describe "AUTH" do
    test "no credentials does not advertise AUTH" do
      {:ok, _instance} = TestServer.SMTP.start()
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, extensions, client} = SMTPClient.ehlo(client)
      extension_names = Enum.map(extensions, fn {_code, ext} -> ext end)
      refute Enum.any?(extension_names, &String.contains?(&1, "AUTH"))
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "credentials advertises AUTH PLAIN LOGIN" do
      {:ok, _instance} = TestServer.SMTP.start(credentials: [{"user", "pass"}])
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, extensions, client} = SMTPClient.ehlo(client)
      extension_names = Enum.map(extensions, fn {_code, ext} -> ext end)
      assert Enum.any?(extension_names, &String.contains?(&1, "AUTH"))
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "AUTH PLAIN with correct credentials" do
      {:ok, instance} = TestServer.SMTP.start(credentials: [{"alice", "secret"}])
      TestServer.SMTP.add(instance)

      port = TestServer.SMTP.port(instance)

      assert :ok =
               SMTPClient.send_email("localhost", port,
                 from: "a@b.com",
                 to: "c@d.com",
                 body: "auth test",
                 auth: {"alice", "secret"}
               )
    end

    test "AUTH PLAIN with wrong credentials" do
      {:ok, _instance} = TestServer.SMTP.start(credentials: [{"alice", "secret"}])
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, client} = SMTPClient.auth_plain(client, "alice", "wrong")
      assert response =~ "535"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "AUTH LOGIN with correct credentials" do
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

    test "AUTH LOGIN with wrong credentials" do
      {:ok, _instance} = TestServer.SMTP.start(credentials: [{"bob", "password"}])
      port = TestServer.SMTP.port()

      {:ok, client} = SMTPClient.connect("localhost", port)
      {:ok, _, client} = SMTPClient.ehlo(client)
      {:ok, response, client} = SMTPClient.auth_login(client, "bob", "wrong")
      assert response =~ "535"
      SMTPClient.quit(client)
      SMTPClient.close(client)
    end

    test "auth credentials available in email struct" do
      {:ok, instance} = TestServer.SMTP.start(credentials: [{"alice", "secret"}])
      test_pid = self()

      TestServer.SMTP.add(instance,
        to: fn email, state ->
          send(test_pid, {:auth, email.auth})
          {:ok, state}
        end
      )

      port = TestServer.SMTP.port(instance)

      :ok =
        SMTPClient.send_email("localhost", port,
          from: "a@b.com",
          to: "c@d.com",
          body: "auth test",
          auth: {"alice", "secret"}
        )

      assert_receive {:auth, {"alice", "secret"}}
    end
  end

  describe "verification" do
    test "raises when handlers not consumed" do
      defmodule HandlersNotConsumedTest do
        use ExUnit.Case

        test "fails" do
          {:ok, instance} = TestServer.SMTP.start()

          TestServer.SMTP.add(instance,
            match: fn email, _state -> email.mail_from == "expected@example.com" end,
            to: fn _email, state -> {:ok, state} end
          )
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "did not receive expected emails"
    end

    test "raises on unexpected email with no handlers" do
      defmodule UnexpectedEmailTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.SMTP.start(suppress_warning: true)
          port = TestServer.SMTP.port()

          {:ok, client} = SMTPClient.connect("localhost", port)
          {:ok, _, client} = SMTPClient.ehlo(client)
          {:ok, _, client} = SMTPClient.mail_from(client, "surprise@example.com")
          {:ok, _, client} = SMTPClient.rcpt_to(client, "c@d.com")
          {:ok, _, client} = SMTPClient.data(client, "Subject: Test\r\n\r\nunexpected")
          SMTPClient.quit(client)
          SMTPClient.close(client)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "received an unexpected SMTP email"
    end
  end

  describe "validation" do
    test "raises for non-function match" do
      {:ok, instance} = TestServer.SMTP.start()

      assert_raise ArgumentError, fn ->
        TestServer.SMTP.add(instance, match: "test")
      end

      assert_raise ArgumentError, fn ->
        TestServer.SMTP.add(instance, match: ~r/test/)
      end
    end
  end

  describe "lifecycle" do
    test "auto-assigns port when port: 0" do
      {:ok, _instance} = TestServer.SMTP.start(port: 0)
      port = TestServer.SMTP.port()

      assert is_integer(port)
      assert port > 0
    end

    test "address returns localhost and port" do
      {:ok, _instance} = TestServer.SMTP.start()
      {"localhost", port} = TestServer.SMTP.address()

      assert is_integer(port)
      assert port > 0
    end

    test "multiple instances are isolated" do
      {:ok, instance_1} = TestServer.SMTP.start()
      {:ok, instance_2} = TestServer.SMTP.start()

      refute instance_1 == instance_2

      port_1 = TestServer.SMTP.port(instance_1)
      port_2 = TestServer.SMTP.port(instance_2)
      refute port_1 == port_2

      test_pid = self()

      TestServer.SMTP.add(instance_1,
        to: fn _email, state ->
          send(test_pid, :instance1)
          {:ok, state}
        end
      )

      TestServer.SMTP.add(instance_2,
        to: fn _email, state ->
          send(test_pid, :instance2)
          {:ok, state}
        end
      )

      :ok =
        SMTPClient.send_email("localhost", port_1,
          from: "a@b.com",
          to: "c@d.com",
          body: "test"
        )

      :ok =
        SMTPClient.send_email("localhost", port_2,
          from: "a@b.com",
          to: "c@d.com",
          body: "test"
        )

      assert_receive :instance1
      assert_receive :instance2
    end

    test "stop/0 stops current instance" do
      {:ok, pid} = TestServer.SMTP.start()
      assert :ok = TestServer.SMTP.stop()
      refute Process.alive?(pid)
    end
  end
end
