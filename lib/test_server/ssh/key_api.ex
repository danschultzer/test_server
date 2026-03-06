defmodule TestServer.SSH.KeyAPI do
  @moduledoc false

  @behaviour :ssh_server_key_api

  @impl true
  def host_key(algorithm, daemon_options) do
    private = Keyword.get(daemon_options, :key_cb_private, [])
    host_key = Keyword.fetch!(private, :host_key)

    if algorithm in [:"ssh-rsa", :"rsa-sha2-256", :"rsa-sha2-512"] do
      {:ok, host_key}
    else
      {:error, {:unsupported_algorithm, algorithm}}
    end
  end

  @impl true
  def is_auth_key(public_key, user, daemon_options) do
    instance = daemon_options |> Keyword.get(:key_cb_private, []) |> Keyword.fetch!(:instance)
    GenServer.call(instance, {:is_auth_key, to_string(user), public_key})
  end
end
