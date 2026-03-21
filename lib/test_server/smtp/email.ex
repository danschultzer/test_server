defmodule TestServer.SMTP.Email do
  @moduledoc false

  defstruct [
    :mail_from,
    :rcpt_to,
    :from,
    :to,
    :subject,
    :headers,
    :body,
    :raw,
    :host,
    :auth
  ]

  @type t :: %__MODULE__{
          mail_from: binary(),
          rcpt_to: [binary()],
          from: binary() | nil,
          to: binary() | nil,
          subject: binary() | nil,
          headers: [{binary(), binary()}],
          body: binary(),
          raw: binary(),
          host: binary() | nil,
          auth: {binary(), binary()} | nil
        }

  @doc false
  @spec parse(binary(), keyword()) :: t()
  def parse(data, opts \\ []) do
    raw = data

    {header_section, body} =
      case String.split(data, "\r\n\r\n", parts: 2) do
        [headers, body] -> {headers, body}
        [headers] -> {headers, ""}
      end

    headers = parse_headers(header_section)

    %__MODULE__{
      mail_from: opts[:mail_from],
      rcpt_to: opts[:rcpt_to] || [],
      from: find_header(headers, "from"),
      to: find_header(headers, "to"),
      subject: find_header(headers, "subject"),
      headers: headers,
      body: body,
      raw: raw,
      host: opts[:host],
      auth: opts[:auth]
    }
  end

  defp parse_headers(section) do
    section
    |> String.split("\r\n")
    |> Enum.reduce([], fn
      "", acc ->
        acc

      line, acc ->
        if String.starts_with?(line, " ") or String.starts_with?(line, "\t") do
          # Continuation line — append to previous header
          case acc do
            [{key, value} | rest] -> [{key, value <> " " <> String.trim(line)} | rest]
            [] -> acc
          end
        else
          case String.split(line, ":", parts: 2) do
            [key, value] -> [{String.trim(key), String.trim(value)} | acc]
            _ -> acc
          end
        end
    end)
    |> Enum.reverse()
  end

  defp find_header(headers, name) do
    downcased = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == downcased, do: value
    end)
  end
end
