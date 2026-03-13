defmodule TestServer.SSH.Server do
  @moduledoc false

  @doc false
  @spec start(pid(), keyword()) :: {:ok, keyword()} | {:error, any()}
  def start(instance, options) do
    port = TestServer.open_port(options)
    host_key = host_key(options)
    daemon_options = daemon_options(options, host_key, instance)

    case :ssh.daemon(port, daemon_options) do
      {:ok, daemon_ref} ->
        suppress_ssh_debug_logging()

        options =
          options
          |> Keyword.put(:port, port)
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
  end

  defp host_key(options) do
    Keyword.get_lazy(options, :host_key, fn ->
      :public_key.generate_key({:rsa, 2048, 65_537})
    end)
  end

  defp daemon_options(options, host_key, instance) do
    tmp_dir = String.to_charlist(System.tmp_dir!())

    ipfamily_options =
      case Keyword.get(options, :ipfamily, :inet) do
        :inet -> []
        ipfamily -> [ipfamily]
      end

    auth_options =
      case Keyword.get(options, :credentials, []) do
        [] ->
          [no_auth_needed: true]

        credentials ->
          user_passwords =
            for {user, password} when is_binary(password) <- credentials do
              {String.to_charlist(user), String.to_charlist(password)}
            end

          [user_passwords: user_passwords]
      end

    ipfamily_options ++
      auth_options ++
      [
        key_cb: {TestServer.SSH.KeyAPI, host_key: host_key, instance: instance},
        ssh_cli: {TestServer.SSH.Channel, channel_options(options, instance)},
        system_dir: tmp_dir,
        user_dir: tmp_dir,
        parallel_login: true
      ]
  end

  defp channel_options(options, instance) do
    opts = [instance: instance]

    case Keyword.fetch(options, :listen) do
      {:ok, listen} -> Keyword.put(opts, :listen, listen)
      :error -> opts
    end
  end

  # Erlang's ssh_transport module logs "client/server will use strict KEX ordering"
  # at debug level using logger:debug/1 (bare string, no metadata). Because there's
  # no module metadata, set_module_level/set_application_level can't target it.
  # We use a primary filter that drops matching debug messages instead.
  defp suppress_ssh_debug_logging do
    %{filters: filters} = :logger.get_primary_config()

    case List.keyfind(filters, :suppress_ssh_debug, 0) do
      nil ->
        :logger.add_primary_filter(:suppress_ssh_debug, {
          fn
            %{level: :debug, msg: {:string, ~c"server will use strict KEX ordering"}}, _extra ->
              :stop

            _event, _extra ->
              :ignore
          end,
          []
        })

      _ ->
        :ok
    end
  end
end
