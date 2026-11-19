defmodule TestServer.SSH.KeyAPI do
  @moduledoc false

  @behaviour :ssh_server_key_api

  @impl true
  def host_key(algorithm, daemon_options) do
    host_key = Keyword.fetch!(daemon_options[:key_cb_private], :host_key)
    log_level = Keyword.fetch!(daemon_options[:key_cb_private], :log_level)

    # Sets process log level for the SSH connection which the primary log
    # filter in TestServer.SSH.Server uses. This relies on the host key
    # callback being called during connection init before any logging (e.g. the
    # KEX ordering debug message).
    :logger.update_process_metadata(%{test_server_ssh_log_level: log_level})

    host_key.(algorithm, daemon_options)
  end

  @impl true
  def is_auth_key(public_key, user, daemon_options) do
    is_auth_key = Keyword.fetch!(daemon_options[:key_cb_private], :is_auth_key)

    is_auth_key.(public_key, user, daemon_options)
  end
end
