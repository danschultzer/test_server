defmodule TestServer.SMTP.Session do
  @moduledoc false

  alias TestServer.SMTP.{Email, Instance}

  defstruct [
    :instance,
    :socket,
    :transport,
    :hostname,
    :tls_options,
    :state,
    :mail_from,
    :host,
    :auth,
    rcpt_to: [],
    recv_buffer: ""
  ]

  @doc false
  def start_link(socket, instance, opts) do
    pid = spawn_link(fn -> init(socket, instance, opts) end)
    {:ok, pid}
  end

  defp init(socket, instance, opts) do
    # Wait for socket ownership transfer from Server
    receive do
      :socket_ready -> :ok
    end

    hostname = Keyword.get(opts, :hostname, "localhost")
    tls_options = Keyword.get(opts, :tls_options, [])

    session = %__MODULE__{
      instance: instance,
      socket: socket,
      transport: :gen_tcp,
      hostname: hostname,
      tls_options: tls_options,
      state: :awaiting_helo
    }

    send_line(session, "220 #{hostname} ESMTP TestServer")
    loop(session)
  end

  defp loop(session) do
    case recv_line(session) do
      {:ok, line, session} ->
        case handle_command(line, session) do
          {:continue, session} -> loop(session)
          :quit -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_command(line, session) do
    {command, arg} = parse_command(line)

    case {String.upcase(command), session.state} do
      {"EHLO", state} when state in [:awaiting_helo, :awaiting_helo_tls] ->
        handle_ehlo(arg, session)

      {"HELO", state} when state in [:awaiting_helo, :awaiting_helo_tls] ->
        handle_helo(arg, session)

      {"STARTTLS", :ready} ->
        handle_starttls(session)

      {"AUTH", :ready} ->
        handle_auth(arg, session)

      {"MAIL", :ready} ->
        handle_mail_from(arg, session)

      {"RCPT", :rcpt_to} ->
        handle_rcpt_to(arg, session)

      {"DATA", :rcpt_to} ->
        handle_data(session)

      {"RSET", state} when state in [:ready, :rcpt_to] ->
        handle_rset(session)

      {"QUIT", _state} ->
        handle_quit(session)

      {"NOOP", _state} ->
        send_line(session, "250 Ok")
        {:continue, session}

      {cmd, _state} when cmd in ["EHLO", "HELO"] ->
        send_line(session, "503 5.5.1 Bad sequence of commands")
        {:continue, session}

      {_cmd, _state} ->
        send_line(session, "500 5.5.1 Unrecognized command")
        {:continue, session}
    end
  end

  defp handle_ehlo(hostname, session) do
    extensions = build_extensions(session)

    case extensions do
      [] ->
        send_line(session, "250 #{session.hostname} Hello #{hostname}")

      _ ->
        first = "250-#{session.hostname} Hello #{hostname}"
        mid = Enum.map(Enum.slice(extensions, 0..-2//1), &"250-#{&1}")
        last = "250 #{List.last(extensions)}"
        Enum.each([first | mid] ++ [last], &send_line(session, &1))
    end

    {:continue, %{session | state: :ready, host: hostname}}
  end

  defp handle_helo(hostname, session) do
    send_line(session, "250 #{session.hostname} Hello #{hostname}")
    {:continue, %{session | state: :ready, host: hostname}}
  end

  defp build_extensions(session) do
    extensions = []

    extensions =
      if session.tls_options != [] and session.transport == :gen_tcp do
        extensions ++ ["STARTTLS"]
      else
        extensions
      end

    if Instance.has_credentials?(session.instance) do
      extensions ++ ["AUTH PLAIN LOGIN"]
    else
      extensions
    end
  end

  defp handle_starttls(session) do
    if session.tls_options == [] do
      send_line(session, "454 4.7.0 TLS not available")
      {:continue, session}
    else
      send_line(session, "220 2.0.0 Ready to start TLS")

      case :ssl.handshake(session.socket, session.tls_options) do
        {:ok, ssl_socket} ->
          {:continue,
           %{session | socket: ssl_socket, transport: :ssl, state: :awaiting_helo_tls, recv_buffer: ""}}

        {:error, _reason} ->
          :quit
      end
    end
  end

  defp handle_auth(arg, session) do
    case parse_auth_mechanism(arg) do
      {:plain, data} ->
        handle_auth_plain(data, session)

      {:plain_empty} ->
        send_line(session, "334 ")

        case recv_line(session) do
          {:ok, data, session} -> handle_auth_plain(data, session)
          {:error, _} -> :quit
        end

      {:login} ->
        handle_auth_login(session)

      :unknown ->
        send_line(session, "504 5.5.4 Unrecognized authentication type")
        {:continue, session}
    end
  end

  defp handle_auth_plain(base64_data, session) do
    case Base.decode64(base64_data) do
      {:ok, decoded} ->
        # PLAIN format: \0username\0password
        case String.split(decoded, <<0>>, parts: 3) do
          [_, username, password] ->
            check_credentials(username, password, session)

          [username, password] ->
            check_credentials(username, password, session)

          _ ->
            send_line(session, "501 5.5.2 Invalid AUTH PLAIN data")
            {:continue, session}
        end

      :error ->
        send_line(session, "501 5.5.2 Invalid base64 data")
        {:continue, session}
    end
  end

  defp handle_auth_login(session) do
    send_line(session, "334 " <> Base.encode64("Username:"))

    case recv_line(session) do
      {:ok, username_b64, session} ->
        send_line(session, "334 " <> Base.encode64("Password:"))

        case recv_line(session) do
          {:ok, password_b64, session} ->
            with {:ok, username} <- Base.decode64(username_b64),
                 {:ok, password} <- Base.decode64(password_b64) do
              check_credentials(username, password, session)
            else
              _ ->
                send_line(session, "501 5.5.2 Invalid base64 data")
                {:continue, session}
            end

          {:error, _} ->
            :quit
        end

      {:error, _} ->
        :quit
    end
  end

  defp check_credentials(username, password, session) do
    case Instance.check_credentials(session.instance, username, password) do
      true ->
        send_line(session, "235 2.7.0 Authentication successful")
        {:continue, %{session | auth: {username, password}}}

      false ->
        send_line(session, "535 5.7.8 Authentication credentials invalid")
        {:continue, session}
    end
  end

  defp handle_mail_from(arg, session) do
    case parse_address(arg, "FROM") do
      {:ok, address} ->
        send_line(session, "250 2.1.0 Ok")
        {:continue, %{session | mail_from: address, rcpt_to: [], state: :rcpt_to}}

      :error ->
        send_line(session, "501 5.1.7 Bad sender address syntax")
        {:continue, session}
    end
  end

  defp handle_rcpt_to(arg, session) do
    case parse_address(arg, "TO") do
      {:ok, address} ->
        send_line(session, "250 2.1.5 Ok")
        {:continue, %{session | rcpt_to: session.rcpt_to ++ [address]}}

      :error ->
        send_line(session, "501 5.1.3 Bad recipient address syntax")
        {:continue, session}
    end
  end

  defp handle_data(session) do
    send_line(session, "354 End data with <CR><LF>.<CR><LF>")

    case recv_data(session) do
      {:ok, data, session} ->
        email =
          Email.parse(data,
            mail_from: session.mail_from,
            rcpt_to: session.rcpt_to,
            host: session.host,
            auth: session.auth
          )

        case Instance.dispatch(session.instance, email) do
          {:ok, response} ->
            send_line(session, response)

          {:error, :not_found} ->
            message =
              "#{TestServer.format_instance(TestServer.SMTP, session.instance)} received an unexpected SMTP email from #{session.mail_from}"

            Instance.report_error(
              session.instance,
              {RuntimeError.exception(message), []}
            )

            send_line(session, "550 5.0.0 No handler registered")

          {:error, {exception, stacktrace}} ->
            Instance.report_error(session.instance, {exception, stacktrace})
            send_line(session, "451 4.0.0 Internal error")
        end

        {:continue, %{session | mail_from: nil, rcpt_to: [], state: :ready}}

      {:error, _reason} ->
        :quit
    end
  end

  defp handle_rset(session) do
    send_line(session, "250 2.0.0 Ok")
    {:continue, %{session | mail_from: nil, rcpt_to: [], state: :ready}}
  end

  defp handle_quit(session) do
    send_line(session, "221 2.0.0 Bye")
    :quit
  end

  # Line I/O — all recv functions return {:ok, data, session} to thread the buffer

  defp send_line(%{transport: :gen_tcp, socket: socket}, line) do
    :gen_tcp.send(socket, line <> "\r\n")
  end

  defp send_line(%{transport: :ssl, socket: socket}, line) do
    :ssl.send(socket, line <> "\r\n")
  end

  defp recv_line(session) do
    recv_until(session, "\r\n")
  end

  defp recv_until(%{recv_buffer: buffer} = session, delimiter) do
    case String.split(buffer, delimiter, parts: 2) do
      [line, rest] ->
        {:ok, line, %{session | recv_buffer: rest}}

      [_incomplete] ->
        case do_recv(session) do
          {:ok, data} ->
            recv_until(%{session | recv_buffer: buffer <> data}, delimiter)

          error ->
            error
        end
    end
  end

  defp recv_data(session) do
    recv_data_lines(session, "")
  end

  defp recv_data_lines(session, buffer) do
    case recv_line(session) do
      {:ok, ".", session} ->
        {:ok, buffer, session}

      {:ok, line, session} ->
        # Dot-stuffing: lines starting with "." have the leading dot removed
        line =
          case line do
            "." <> rest -> rest
            other -> other
          end

        recv_data_lines(session, buffer <> line <> "\r\n")

      error ->
        error
    end
  end

  defp do_recv(%{transport: :gen_tcp, socket: socket}) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, data} -> {:ok, IO.iodata_to_binary(data)}
      error -> error
    end
  end

  defp do_recv(%{transport: :ssl, socket: socket}) do
    case :ssl.recv(socket, 0, 30_000) do
      {:ok, data} -> {:ok, IO.iodata_to_binary(data)}
      error -> error
    end
  end

  # Parsing helpers

  defp parse_command(line) do
    case String.split(line, " ", parts: 2) do
      [command, arg] -> {command, String.trim(arg)}
      [command] -> {command, ""}
    end
  end

  defp parse_auth_mechanism(arg) do
    case String.split(arg, " ", parts: 2) do
      ["PLAIN", data] -> {:plain, data}
      ["PLAIN"] -> {:plain_empty}
      ["LOGIN" | _] -> {:login}
      _ -> :unknown
    end
  end

  defp parse_address(arg, prefix) do
    # Match "FROM:<addr>" or "TO:<addr>" (case-insensitive prefix)
    pattern = ~r/^#{prefix}:\s*<([^>]*)>/i

    case Regex.run(pattern, arg) do
      [_, address] -> {:ok, address}
      _ -> :error
    end
  end
end
