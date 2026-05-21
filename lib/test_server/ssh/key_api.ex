defmodule TestServer.SSH.KeyAPI do
  @moduledoc false

  @behaviour :ssh_server_key_api

  @impl true
  def host_key(algorithm, daemon_options) do
    host_key = Keyword.fetch!(daemon_options[:key_cb_private], :host_key)

    host_key.(algorithm, daemon_options)
  end

  @impl true
  def is_auth_key(public_key, user, daemon_options) do
    is_auth_key = Keyword.fetch!(daemon_options[:key_cb_private], :is_auth_key)

    is_auth_key.(public_key, user, daemon_options)
  end
end
