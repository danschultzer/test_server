# TestServer.SMTP

<!-- MDOC !-->

`TestServer.SMTP` is a real SMTP server for testing email workflows in ExUnit.

It runs in your test process — no Docker, no external services, no port conflicts.
Start it, register handlers, send email through it, and assert on what was received.

## Usage

```elixir
test "sends welcome email" do
  {:ok, instance} = TestServer.SMTP.start()

  test_pid = self()

  TestServer.SMTP.add(instance,
    match: fn email, _state -> email.subject == "Welcome" end,
    to: fn email, state ->
      send(test_pid, {:email, email})
      {:ok, state}
    end
  )

  # Point your SMTP client at the test server
  port = TestServer.SMTP.port(instance)
  MyApp.Mailer.send_welcome(smtp_port: port)

  assert_receive {:email, email}
  assert email.mail_from == "noreply@myapp.com"
  assert "user@example.com" in email.rcpt_to
end
```

## Features

- **FIFO handler dispatch** — same pattern as `TestServer.HTTP` and `TestServer.SSH`
- **STARTTLS** — auto-generated self-signed certificates via `x509`
- **AUTH PLAIN/LOGIN** — configurable credentials
- **Parsed email struct** — `mail_from`, `rcpt_to`, `subject`, `headers`, `body`
- **Custom SMTP responses** — simulate bounces, rejected recipients, auth failures
- **Zero dependencies** — built on OTP's `:gen_tcp` and `:ssl`

## Handler responses

Handlers return a tagged tuple indicating success or failure:

```elixir
# Accept (sends "250 2.0.0 Ok")
{:ok, state}

# Accept with custom message
{:ok, "250 2.0.0 Queued as ABC123", state}

# Reject (sends "550 5.0.0 Rejected")
{:error, state}

# Reject with custom message
{:error, "550 5.1.1 User unknown", state}
```

## Options

- `:port` — port number (default: random available port)
- `:hostname` — server hostname (default: `"localhost"`)
- `:tls` — set to `true` for STARTTLS support
- `:credentials` — list of `{username, password}` tuples for AUTH

<!-- MDOC !-->
