defmodule TestServer.SMTP.Session do
  @moduledoc false

  # credo:disable-for-this-file Credo.Check.Readability.FunctionNames
  @behaviour :gen_smtp_server_session

  alias TestServer.SMTP.Instance

  @impl true
  def init(hostname, _count, _address, opts) do
    state = %{instance: opts[:instance], from: nil, to: [], options: opts}
    {:ok, "#{hostname} ESMTP TestServer", state}
  end

  @impl true
  def handle_HELO(_hostname, state) do
    {:ok, state}
  end

  @impl true
  def handle_EHLO(_hostname, extensions, state) do
    extensions =
      if state.options[:tls] == :starttls do
        extensions ++ [{~c"STARTTLS", true}]
      else
        extensions
      end

    extensions =
      if state.options[:credentials] do
        extensions ++ [{~c"AUTH", ~c"PLAIN LOGIN"}]
      else
        extensions
      end

    {:ok, extensions, state}
  end

  @impl true
  def handle_MAIL(from, state) do
    {:ok, %{state | from: from}}
  end

  @impl true
  def handle_MAIL_extension(_extension, state) do
    {:ok, state}
  end

  @impl true
  def handle_RCPT(to, state) do
    {:ok, %{state | to: state.to ++ [to]}}
  end

  @impl true
  def handle_RCPT_extension(_extension, state) do
    {:ok, state}
  end

  @impl true
  def handle_DATA(from, to, data, state) do
    email = build_email(from, to, data)

    case GenServer.call(state.instance, {:dispatch, email}) do
      {:ok, _} ->
        {:ok, "OK", state}

      {:error, :not_found} ->
        message =
          "#{Instance.format_instance(state.instance)} received an unexpected SMTP email from #{from}"

        Instance.report_error(state.instance, {RuntimeError.exception(message), []})
        {:error, "550 No handler registered for this email", state}

      {:error, {exception, stacktrace}} ->
        Instance.report_error(state.instance, {exception, stacktrace})
        {:error, "500 Error processing email", state}
    end
  end

  @impl true
  def handle_RSET(state) do
    %{state | from: nil, to: []}
  end

  @impl true
  def handle_VRFY(_address, state) do
    {:error, "252 Cannot VRFY user, but will accept message", state}
  end

  @impl true
  def handle_other(verb, _args, state) do
    {"500 Error: bad syntax - unrecognized command '#{verb}'", state}
  end

  @impl true
  def handle_AUTH(type, user, pass, state) when type in [:plain, :login] do
    case GenServer.call(state.instance, {:check_credentials, to_string(user), to_string(pass)}) do
      true -> {:ok, state}
      false -> :error
    end
  end

  def handle_AUTH(_type, _user, _pass, _state), do: :error

  @impl true
  def handle_STARTTLS(state) do
    state
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    {:ok, state}
  end

  defp build_email(from, to, data) do
    raw = to_string(data)

    {top_headers, text_body, html_body, attachments} =
      try do
        decoded = :mimemail.decode(data)
        parse_mime(decoded)
      rescue
        _ -> {[], nil, nil, []}
      end

    %TestServer.SMTP.Email{
      mail_from: to_string(from),
      rcpt_to: Enum.map(to, &to_string/1),
      from: find_header(top_headers, "from"),
      to: find_header(top_headers, "to"),
      cc: find_header(top_headers, "cc"),
      subject: find_header(top_headers, "subject"),
      date: find_header(top_headers, "date"),
      message_id: find_header(top_headers, "message-id"),
      headers: top_headers,
      text_body: text_body,
      html_body: html_body,
      attachments: attachments,
      raw: raw
    }
  end

  # Returns {headers, text_body, html_body, attachments}
  defp parse_mime({"text", "plain", headers, _params, body}) do
    {normalize_headers(headers), to_string(body), nil, []}
  end

  defp parse_mime({"text", "html", headers, _params, body}) do
    {normalize_headers(headers), nil, to_string(body), []}
  end

  defp parse_mime({"multipart", _subtype, headers, _params, parts}) when is_list(parts) do
    {text, html, attachments} =
      Enum.reduce(parts, {nil, nil, []}, fn part, {t, h, atts} ->
        {_ph, pt, ph, patt} = parse_mime(part)
        {t || pt, h || ph, atts ++ patt}
      end)

    {normalize_headers(headers), text, html, attachments}
  end

  defp parse_mime({type, subtype, headers, _params, body}) do
    hs = normalize_headers(headers)

    if attachment?(hs) do
      attachment = %{
        filename: get_filename(hs),
        content_type: "#{type}/#{subtype}",
        data: body,
        headers: hs
      }

      {hs, nil, nil, [attachment]}
    else
      {hs, nil, nil, []}
    end
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp attachment?(headers) do
    Enum.any?(headers, fn {k, v} ->
      String.downcase(k) == "content-disposition" and
        String.downcase(v) |> String.starts_with?("attachment")
    end)
  end

  defp get_filename(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == "content-disposition" do
        case Regex.run(~r/filename="?([^";]+)"?/i, v) do
          [_, name] -> name
          _ -> nil
        end
      end
    end)
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end
end
