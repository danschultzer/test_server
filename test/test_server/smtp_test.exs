defmodule TestServer.SMTPTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias TestServer.SMTPClient

  describe "start/1" do
    test "auto-assigns port" do
      {:ok, instance} = TestServer.SMTP.start()
      {_host, port} = TestServer.SMTP.address(instance)
      assert is_integer(port) and port > 0
    end

    test "multiple independent instances have different ports" do
      {:ok, instance_1} = TestServer.SMTP.start()
      {:ok, instance_2} = TestServer.SMTP.start()
      {_, port1} = TestServer.SMTP.address(instance_1)
      {_, port2} = TestServer.SMTP.address(instance_2)
      refute port1 == port2
    end
  end

  describe "receive_mail/1" do
    test "basic handler receives email" do
      test_pid = self()

      TestServer.SMTP.receive_mail(
        to: fn email, state ->
          send(test_pid, {:received, email})
          {:ok, state}
        end
      )

      {host, port} = TestServer.SMTP.address()

      :ok =
        SMTPClient.send_email(host, port,
          from: "sender@example.com",
          to: "recipient@example.com",
          subject: "Hello",
          body: "World"
        )

      assert_receive {:received, email}
      assert email.mail_from == "sender@example.com"
      assert "recipient@example.com" in email.rcpt_to
    end

    test "FIFO consumption order" do
      test_pid = self()

      TestServer.SMTP.receive_mail(
        to: fn _email, state ->
          send(test_pid, :first)
          {:ok, state}
        end
      )

      TestServer.SMTP.receive_mail(
        to: fn _email, state ->
          send(test_pid, :second)
          {:ok, state}
        end
      )

      {host, port} = TestServer.SMTP.address()

      :ok = SMTPClient.send_email(host, port, from: "a@b.com", to: "c@d.com", body: "1")
      :ok = SMTPClient.send_email(host, port, from: "a@b.com", to: "c@d.com", body: "2")

      assert_receive :first
      assert_receive :second
    end

    test "match: filters which handler runs" do
      test_pid = self()

      TestServer.SMTP.receive_mail(
        match: fn email, _state -> email.subject == "Special" end,
        to: fn email, state ->
          send(test_pid, {:matched, email.subject})
          {:ok, state}
        end
      )

      {host, port} = TestServer.SMTP.address()

      :ok =
        SMTPClient.send_email(host, port,
          from: "a@b.com",
          to: "c@d.com",
          subject: "Special",
          body: "test"
        )

      assert_receive {:matched, "Special"}
    end
  end

  describe "error cases" do
    test "unmatched email reports error at test exit" do
      defmodule UnmatchedSMTPTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SMTP.receive_mail(
            match: fn email, _state -> email.subject == "Expected" end,
            to: fn _email, state -> {:ok, state} end
          )

          {host, port} = TestServer.SMTP.address()

          TestServer.SMTPClient.send_email(host, port,
            from: "a@b.com",
            to: "c@d.com",
            subject: "Other",
            body: "test"
          )
        end
      end

      log =
        capture_io(:stderr, fn ->
          capture_io(fn -> ExUnit.run() end)
        end)

      assert log =~ "received an unexpected SMTP email"
    end

    test "unconsumed handler raises at test exit" do
      defmodule UnconsumedSMTPTest do
        use ExUnit.Case

        test "fails" do
          TestServer.SMTP.receive_mail(to: fn _email, state -> {:ok, state} end)
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "did not receive mail"
    end
  end

  describe "email struct" do
    test "mail_from and rcpt_to populated from envelope" do
      test_pid = self()

      TestServer.SMTP.receive_mail(
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      {host, port} = TestServer.SMTP.address()

      :ok =
        SMTPClient.send_email(host, port,
          from: "sender@example.com",
          to: ["recip1@example.com", "recip2@example.com"],
          body: "multi"
        )

      assert_receive {:email, email}
      assert email.mail_from == "sender@example.com"
      assert "recip1@example.com" in email.rcpt_to
      assert "recip2@example.com" in email.rcpt_to
    end

    test "subject and headers parsed" do
      test_pid = self()

      TestServer.SMTP.receive_mail(
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      {host, port} = TestServer.SMTP.address()

      :ok =
        SMTPClient.send_email(host, port,
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

    test "text_body extracted from plain text email" do
      test_pid = self()

      TestServer.SMTP.receive_mail(
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      {host, port} = TestServer.SMTP.address()

      :ok =
        SMTPClient.send_email(host, port,
          from: "a@b.com",
          to: "c@d.com",
          subject: "Plain",
          body: "Hello plain text"
        )

      assert_receive {:email, email}
      assert email.text_body =~ "Hello plain text"
    end

    test "raw field contains full DATA payload" do
      test_pid = self()

      TestServer.SMTP.receive_mail(
        to: fn email, state ->
          send(test_pid, {:email, email})
          {:ok, state}
        end
      )

      {host, port} = TestServer.SMTP.address()

      :ok =
        SMTPClient.send_email(host, port,
          from: "a@b.com",
          to: "c@d.com",
          body: "raw content"
        )

      assert_receive {:email, email}
      assert is_binary(email.raw)
      assert email.raw =~ "raw content"
    end
  end

  describe "TLS / STARTTLS" do
    test "plain SMTP works without TLS" do
      {:ok, instance} = TestServer.SMTP.start()

      TestServer.SMTP.receive_mail(instance, to: fn _email, state -> {:ok, state} end)

      {host, port} = TestServer.SMTP.address(instance)
      assert :ok = SMTPClient.send_email(host, port, from: "a@b.com", to: "c@d.com", body: "hi")
    end

    test "STARTTLS upgrade works" do
      {:ok, instance} = TestServer.SMTP.start(tls: :starttls)

      TestServer.SMTP.receive_mail(instance, to: fn _email, state -> {:ok, state} end)

      {host, port} = TestServer.SMTP.address(instance)

      assert :ok =
               SMTPClient.send_email(host, port,
                 from: "a@b.com",
                 to: "c@d.com",
                 body: "tls test",
                 tls: true
               )
    end

    test "x509_suite/0 returns suite when TLS enabled" do
      {:ok, _instance} = TestServer.SMTP.start(tls: :starttls)
      suite = TestServer.SMTP.x509_suite()
      assert suite != nil
      assert %X509.Test.Suite{} = suite
    end

    test "x509_suite/0 returns nil when TLS not enabled" do
      {:ok, _instance} = TestServer.SMTP.start()
      assert TestServer.SMTP.x509_suite() == nil
    end
  end

  describe "AUTH" do
    test "no credentials accepts any client" do
      {:ok, instance} = TestServer.SMTP.start()
      TestServer.SMTP.receive_mail(instance, to: fn _email, state -> {:ok, state} end)
      {host, port} = TestServer.SMTP.address(instance)
      assert :ok = SMTPClient.send_email(host, port, from: "a@b.com", to: "c@d.com", body: "hi")
    end

    test "valid credentials accepted" do
      {:ok, instance} = TestServer.SMTP.start(credentials: [{"alice", "secret"}])
      TestServer.SMTP.receive_mail(instance, to: fn _email, state -> {:ok, state} end)
      {host, port} = TestServer.SMTP.address(instance)

      assert :ok =
               SMTPClient.send_email(host, port,
                 from: "a@b.com",
                 to: "c@d.com",
                 body: "hi",
                 auth: {"alice", "secret"}
               )
    end

    test "wrong password rejected" do
      {:ok, instance} = TestServer.SMTP.start(credentials: [{"alice", "secret"}])
      {host, port} = TestServer.SMTP.address(instance)

      {:ok, sock} = SMTPClient.connect(host, port)
      {:ok, _} = SMTPClient.ehlo(sock)
      {:ok, response} = SMTPClient.auth_plain(sock, "alice", "wrong")
      assert response =~ "535"
      SMTPClient.close(sock)
    end
  end

  describe "multi-instance" do
    test "error when multiple instances and no explicit instance arg" do
      {:ok, _instance_1} = TestServer.SMTP.start()
      {:ok, _instance_2} = TestServer.SMTP.start()

      assert_raise RuntimeError, ~r/Multiple.*running.*pass instance/, fn ->
        TestServer.SMTP.address()
      end
    end

    test "explicit instance arg works with multiple instances" do
      {:ok, instance_1} = TestServer.SMTP.start()
      {:ok, instance_2} = TestServer.SMTP.start()

      {_, port1} = TestServer.SMTP.address(instance_1)
      {_, port2} = TestServer.SMTP.address(instance_2)

      refute port1 == port2
    end
  end

  describe "address/0" do
    test "returns localhost and port" do
      {:ok, _instance} = TestServer.SMTP.start()
      {host, port} = TestServer.SMTP.address()
      assert host == "localhost"
      assert is_integer(port) and port > 0
    end
  end
end
