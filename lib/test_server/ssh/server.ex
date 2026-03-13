defmodule TestServer.SSH.Server do
  @moduledoc false

  @doc false
  @spec start(pid(), keyword()) :: {:ok, keyword()} | {:error, any()}
  def start(instance, options) do
    port = TestServer.open_port(options)

    host_key = host_key(options)

    ip = Keyword.get(options, :ip, {127, 0, 0, 1})
    suppress_ssh_debug_logging()
    daemon_options = daemon_options(options, host_key, instance)

    case :ssh.daemon(ip, port, daemon_options) do
      {:ok, daemon_ref} ->
        resolved_port = resolve_port(daemon_ref)

        options =
          options
          |> Keyword.put(:port, resolved_port)
          |> Keyword.put(:ip, ip)
          |> Keyword.put(:daemon_ref, daemon_ref)

        {:ok, options}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec stop(keyword()) :: :ok
  def stop(options) do
    daemon_ref = Keyword.fetch!(options, :daemon_ref)

    :ssh.stop_daemon(daemon_ref)
    :logger.remove_primary_filter(:suppress_ssh_debug)
  end

  defp host_key(options) do
    Keyword.get_lazy(options, :host_key, fn ->
      :public_key.generate_key({:rsa, 2048, 65_537})
    end)
  end

  defp daemon_options(options, host_key, instance) do
    tmp_dir = String.to_charlist(System.tmp_dir!())

    [
      key_cb: {TestServer.SSH.KeyAPI, host_key: host_key, instance: instance},
      ssh_cli: {TestServer.SSH.Channel, instance: instance},
      system_dir: tmp_dir,
      user_dir: tmp_dir,
      parallel_login: true
    ] ++ auth_options(Keyword.get(options, :credentials, []))
  end

  defp auth_options([]), do: [no_auth_needed: true]

  defp auth_options(credentials) do
    user_passwords =
      for {user, password} when is_binary(password) <- credentials do
        {String.to_charlist(user), String.to_charlist(password)}
      end

    [user_passwords: user_passwords]
  end

  # Erlang's ssh_transport module logs "client/server will use strict KEX ordering"
  # at debug level using logger:debug/1 (bare string, no metadata). Because there's
  # no module metadata, set_module_level/set_application_level can't target it.
  # We use a primary filter that drops debug messages in raw string format instead.
  defp suppress_ssh_debug_logging do
    :logger.add_primary_filter(:suppress_ssh_debug, {
      fn
        %{level: :debug, msg: {:string, _}}, _extra -> :stop
        _event, _extra -> :ignore
      end,
      []
    })
  end

  defp resolve_port(daemon_ref) do
    {:ok, info} = :ssh.daemon_info(daemon_ref)
    {_, port} = List.keyfind(info, :port, 0)

    port
  end
end
