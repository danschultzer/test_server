defmodule TestServer.SMTPClient do
  @moduledoc false

  @timeout 5_000

  defstruct [:socket, :transport, recv_buffer: ""]

  @doc """
  Connect to an SMTP server and read the greeting.
  """
  def connect(host, port, _opts \\ []) do
    host = if is_binary(host), do: String.to_charlist(host), else: host

    case :gen_tcp.connect(host, port, [:binary, packet: :raw, active: false], @timeout) do
      {:ok, socket} ->
        client = %__MODULE__{socket: socket, transport: :gen_tcp}

        case recv_line(client) do
          {:ok, "220" <> _rest, client} -> {:ok, client}
          {:ok, line, _client} -> {:error, {:unexpected_greeting, line}}
          error -> error
        end

      error ->
        error
    end
  end

  @doc """
  Send EHLO and return the list of extensions.
  Returns {:ok, extensions, client} where extensions is a list of {code, text} tuples.
  """
  def ehlo(client, hostname \\ "test.local") do
    send_line(client, "EHLO #{hostname}")
    recv_multiline(client)
  end

  @doc """
  Send HELO.
  """
  def helo(client, hostname \\ "test.local") do
    send_line(client, "HELO #{hostname}")
    recv_response(client)
  end

  @doc """
  Send MAIL FROM.
  """
  def mail_from(client, address) do
    send_line(client, "MAIL FROM:<#{address}>")
    recv_response(client)
  end

  @doc """
  Send RCPT TO.
  """
  def rcpt_to(client, address) do
    send_line(client, "RCPT TO:<#{address}>")
    recv_response(client)
  end

  @doc """
  Send DATA with the message body.
  """
  def data(client, message) do
    send_line(client, "DATA")

    case recv_response(client) do
      {:ok, "354" <> _, client} ->
        # Send message body, dot-stuff lines starting with "."
        lines = String.split(message, "\r\n")

        stuffed =
          Enum.map(lines, fn
            "." <> _ = line -> "." <> line
            line -> line
          end)

        send_raw(client, Enum.join(stuffed, "\r\n") <> "\r\n.\r\n")
        recv_response(client)

      {:ok, error, _client} ->
        {:error, error}

      error ->
        error
    end
  end

  @doc """
  Upgrade connection to TLS via STARTTLS.
  """
  def starttls(client) do
    send_line(client, "STARTTLS")

    case recv_response(client) do
      {:ok, "220" <> _, _client} ->
        case :ssl.connect(client.socket, [verify: :verify_none], @timeout) do
          {:ok, ssl_socket} ->
            {:ok, %{client | socket: ssl_socket, transport: :ssl, recv_buffer: ""}}

          error ->
            error
        end

      {:ok, error, _client} ->
        {:error, error}

      error ->
        error
    end
  end

  @doc """
  AUTH PLAIN.
  """
  def auth_plain(client, username, password) do
    encoded = Base.encode64(<<0, username::binary, 0, password::binary>>)
    send_line(client, "AUTH PLAIN #{encoded}")
    recv_response(client)
  end

  @doc """
  AUTH LOGIN.
  """
  def auth_login(client, username, password) do
    send_line(client, "AUTH LOGIN")

    case recv_response(client) do
      {:ok, "334" <> _, client} ->
        send_line(client, Base.encode64(username))

        case recv_response(client) do
          {:ok, "334" <> _, client} ->
            send_line(client, Base.encode64(password))
            recv_response(client)

          result ->
            result
        end

      result ->
        result
    end
  end

  @doc """
  Send RSET.
  """
  def rset(client) do
    send_line(client, "RSET")
    recv_response(client)
  end

  @doc """
  Send QUIT.
  """
  def quit(client) do
    send_line(client, "QUIT")
    recv_response(client)
  end

  @doc """
  Close the connection.
  """
  def close(%{transport: :gen_tcp, socket: socket}), do: :gen_tcp.close(socket)
  def close(%{transport: :ssl, socket: socket}), do: :ssl.close(socket)

  @doc """
  Convenience: send a complete email in one call.
  """
  def send_email(host, port, opts \\ []) do
    from = Keyword.fetch!(opts, :from)
    to = List.wrap(Keyword.fetch!(opts, :to))
    subject = Keyword.get(opts, :subject, "")
    body = Keyword.get(opts, :body, "")
    auth = Keyword.get(opts, :auth)
    tls = Keyword.get(opts, :tls, false)

    {:ok, client} = connect(host, port)
    {:ok, _, client} = ehlo(client)

    client =
      if tls do
        {:ok, client} = starttls(client)
        {:ok, _, client} = ehlo(client)
        client
      else
        client
      end

    client =
      if auth do
        {user, pass} = auth
        {:ok, "235" <> _, client} = auth_plain(client, user, pass)
        client
      else
        client
      end

    {:ok, "250" <> _, client} = mail_from(client, from)

    client =
      Enum.reduce(to, client, fn recipient, client ->
        {:ok, "250" <> _, client} = rcpt_to(client, recipient)
        client
      end)

    message =
      "From: #{from}\r\n" <>
        "To: #{Enum.join(to, ", ")}\r\n" <>
        "Subject: #{subject}\r\n" <>
        "\r\n" <>
        body

    {:ok, "250" <> _, client} = data(client, message)
    quit(client)
    close(client)

    :ok
  end

  @doc """
  Send a raw command.
  """
  def send_command(client, command) do
    send_line(client, command)
    recv_response(client)
  end

  # Internal

  defp send_line(client, line) do
    send_raw(client, line <> "\r\n")
  end

  defp send_raw(%{transport: :gen_tcp, socket: socket}, data) do
    :gen_tcp.send(socket, data)
  end

  defp send_raw(%{transport: :ssl, socket: socket}, data) do
    :ssl.send(socket, data)
  end

  defp recv_response(client) do
    recv_line(client)
  end

  defp recv_line(client) do
    recv_until(client, "\r\n")
  end

  defp recv_multiline(client) do
    recv_multiline(client, [])
  end

  defp recv_multiline(client, acc) do
    case recv_line(client) do
      {:ok, <<code::binary-size(3), "-", rest::binary>>, client} ->
        recv_multiline(client, acc ++ [{code, rest}])

      {:ok, <<code::binary-size(3), " ", rest::binary>>, client} ->
        {:ok, acc ++ [{code, rest}], client}

      {:ok, line, client} ->
        {:ok, acc ++ [{line, ""}], client}

      error ->
        error
    end
  end

  defp recv_until(%{recv_buffer: buffer} = client, delimiter) do
    case String.split(buffer, delimiter, parts: 2) do
      [line, rest] ->
        {:ok, line, %{client | recv_buffer: rest}}

      [_incomplete] ->
        case do_recv(client) do
          {:ok, data} ->
            recv_until(%{client | recv_buffer: buffer <> data}, delimiter)

          error ->
            error
        end
    end
  end

  defp do_recv(%{transport: :gen_tcp, socket: socket}) do
    case :gen_tcp.recv(socket, 0, @timeout) do
      {:ok, data} -> {:ok, IO.iodata_to_binary(data)}
      error -> error
    end
  end

  defp do_recv(%{transport: :ssl, socket: socket}) do
    case :ssl.recv(socket, 0, @timeout) do
      {:ok, data} -> {:ok, IO.iodata_to_binary(data)}
      error -> error
    end
  end
end
