defmodule TestServer.SMTP.Email do
  @moduledoc false

  defstruct [
    :mail_from,
    :rcpt_to,
    :from,
    :to,
    :cc,
    :subject,
    :date,
    :message_id,
    :headers,
    :text_body,
    :html_body,
    :attachments,
    :raw
  ]
end
