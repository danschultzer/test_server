defmodule TestServer.SMTPClient do
  @moduledoc false

  @timeout 5_000

  def connect(host, port, _opts \\ []) do
    host_charlist = String.to_charlist(host)

    case :gen_tcp.connect(host_charlist, port, [:binary, active: false], @timeout) do
      {:ok, socket} ->
        case recv({:tcp, socket}) do
          {:ok, "220" <> _} -> {:ok, {:tcp, socket}}
          {:ok, response} -> {:error, {:unexpected_banner, response}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_command({:tcp, socket} = sock, command) do
    :ok = :gen_tcp.send(socket, command <> "\r\n")
    recv(sock)
  end

  def send_command({:ssl, socket} = sock, command) do
    :ok = :ssl.send(socket, command <> "\r\n")
    recv(sock)
  end

  def ehlo(sock, hostname \\ "test.local") do
    send_command(sock, "EHLO #{hostname}")
  end

  def mail_from(sock, address) do
    send_command(sock, "MAIL FROM:<#{address}>")
  end

  def rcpt_to(sock, address) do
    send_command(sock, "RCPT TO:<#{address}>")
  end

  def data(sock, body) do
    {:ok, _} = send_command(sock, "DATA")
    send_raw(sock, normalize_body(body) <> "\r\n.\r\n")
    recv(sock)
  end

  def quit(sock) do
    send_command(sock, "QUIT")
  end

  def close({:tcp, socket}), do: :gen_tcp.close(socket)
  def close({:ssl, socket}), do: :ssl.close(socket)

  def starttls(sock, ssl_opts \\ []) do
    {:ok, _} = send_command(sock, "STARTTLS")
    {:tcp, socket} = sock
    ssl_opts = Keyword.merge([verify: :verify_none], ssl_opts)

    case :ssl.connect(socket, ssl_opts, @timeout) do
      {:ok, ssl_socket} -> {:ok, {:ssl, ssl_socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  def auth_plain(sock, user, pass) do
    credentials = Base.encode64("\0#{user}\0#{pass}")
    send_command(sock, "AUTH PLAIN #{credentials}")
  end

  def send_email(host, port, opts) do
    from = Keyword.fetch!(opts, :from)
    to_list = List.wrap(Keyword.fetch!(opts, :to))
    subject = Keyword.get(opts, :subject, "Test Email")
    body = Keyword.get(opts, :body, "Test body")
    use_tls = Keyword.get(opts, :tls, false)
    auth = Keyword.get(opts, :auth, nil)
    ssl_opts = Keyword.get(opts, :ssl_opts, [])

    {:ok, sock} = connect(host, port)
    {:ok, _} = ehlo(sock)

    sock =
      if use_tls do
        {:ok, ssl_sock} = starttls(sock, ssl_opts)
        {:ok, _} = ehlo(ssl_sock)
        ssl_sock
      else
        sock
      end

    if auth do
      {user, pass} = auth
      {:ok, "235" <> _} = auth_plain(sock, user, pass)
    end

    {:ok, _} = mail_from(sock, from)

    Enum.each(to_list, fn recipient ->
      {:ok, _} = rcpt_to(sock, recipient)
    end)

    message = build_message(from, to_list, subject, body)
    {:ok, _} = data(sock, message)
    quit(sock)
    close(sock)
    :ok
  end

  defp build_message(from, to_list, subject, body) do
    to_str = Enum.join(to_list, ", ")

    "From: #{from}\r\nTo: #{to_str}\r\nSubject: #{subject}\r\n\r\n#{body}"
  end

  defp send_raw({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  defp send_raw({:ssl, socket}, data), do: :ssl.send(socket, data)

  # Read one or more response lines until we get a final line (code + space)
  defp recv(sock) do
    recv_loop(sock, "")
  end

  defp recv_loop(sock, acc) do
    case do_recv(sock) do
      {:ok, data} ->
        full = acc <> data

        # Check if we have a complete response (last line is "XYZ " not "XYZ-")
        lines = String.split(full, "\r\n", trim: true)

        if Enum.any?(lines, &final_line?/1) do
          final_line = Enum.find(lines, &final_line?/1)
          {:ok, final_line}
        else
          recv_loop(sock, full)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_recv({:tcp, socket}) do
    case :gen_tcp.recv(socket, 0, @timeout) do
      {:ok, data} -> {:ok, to_string(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_recv({:ssl, socket}) do
    case :ssl.recv(socket, 0, @timeout) do
      {:ok, data} -> {:ok, to_string(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A final SMTP response line: 3 digits followed by a space (not a dash)
  defp final_line?(line) do
    Regex.match?(~r/^\d{3} /, line)
  end

  # Ensure lines end with \r\n and leading dots are escaped (dot-stuffing)
  defp normalize_body(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> Enum.map_join("\r\n", fn line ->
      if String.starts_with?(line, "."), do: "." <> line, else: line
    end)
  end
end
