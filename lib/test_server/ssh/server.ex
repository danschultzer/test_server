defmodule TestServer.SSH.Server do
  @moduledoc false

  alias TestServer.SSH.Channel

  @doc false
  @spec start(TestServer.instance(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def start(instance, options) do
    with {:ok, port} <- TestServer.open_port(options),
         {host_keys, daemon_options} = daemon_options(instance, options),
         {:ok, daemon_pid} <- :ssh.daemon(port, daemon_options) do
      options =
        options
        |> Keyword.put(:host_keys, host_keys)
        |> Keyword.put(:port, port)
        |> Keyword.put(:daemon, daemon_pid)

      stop_on_exit(options)
      install_ssh_log_filter()

      {:ok, options}
    end
  end

  defp daemon_options(instance, options) do
    tmp_dir = to_charlist(System.tmp_dir!())

    {log_level, daemon_options} =
      options
      |> Keyword.get(:daemon, [])
      |> Keyword.pop(:log_level, :warning)

    validate_log_level!(log_level)

    {host_keys_fn, host_keys} =
      case host_keys(options) do
        key_fun when is_function(key_fun, 2) -> {key_fun, :none}
        host_keys when is_list(host_keys) -> {&default_host_key/2, to_host_key_maps(host_keys)}
      end

    {auth_key_fn, auth_keys} =
      case Keyword.get(options, :auth_keys, []) do
        key_fun when is_function(key_fun, 3) -> {key_fun, []}
        auth_keys when is_list(auth_keys) -> {&default_is_auth_key/3, auth_keys}
      end

    key_cb =
      {
        TestServer.SSH.KeyAPI,
        [
          host_key: host_keys_fn,
          host_keys: host_keys,
          is_auth_key: auth_key_fn,
          auth_keys: auth_keys,
          log_level: log_level
        ]
      }

    ssh_cli =
      {
        Channel,
        options
        |> Keyword.take([:messages])
        |> Keyword.put(:instance, instance)
      }

    daemon_options =
      options
      |> Keyword.take([:no_auth_needed, :user_passwords])
      |> normalize_user_passwords()
      |> Keyword.put_new(
        :no_auth_needed,
        not Keyword.has_key?(options, :auth_keys) and
          not Keyword.has_key?(options, :user_passwords)
      )
      |> Keyword.merge(
        key_cb: key_cb,
        ssh_cli: ssh_cli,
        system_dir: tmp_dir,
        user_dir: tmp_dir,
        parallel_login: true
      )
      |> Keyword.merge(daemon_options)
      |> put_subsystems(instance, options)

    daemon_options =
      case Keyword.get(options, :ipfamily, :inet) do
        :inet -> daemon_options
        ipfamily -> [ipfamily | daemon_options]
      end

    {host_keys, daemon_options}
  end

  @levels [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug, :none, :all]

  defp validate_log_level!(level) when level in @levels, do: :ok

  defp validate_log_level!(level) do
    raise ArgumentError,
          "expected :log_level in :daemon to be one of #{Enum.map_join(@levels, ", ", &inspect/1)}, got: #{inspect(level)}"
  end

  defp host_keys(options) do
    Keyword.get_lazy(options, :host_keys, fn ->
      [
        # `:"rsa-sha2-256"` | `:"rsa-sha2-512"`
        :public_key.generate_key({:rsa, 2_048, 65_537}),
        # `:`ecdsa-sha2-nistp256"`
        :public_key.generate_key({:namedCurve, :secp256r1}),
        # `:`ecdsa-sha2-nistp384"`
        :public_key.generate_key({:namedCurve, :secp384r1}),
        # `:`ecdsa-sha2-nistp521"`
        :public_key.generate_key({:namedCurve, :secp521r1}),
        # `:`ssh-ed25519"`
        :public_key.generate_key({:namedCurve, :ed25519}),
        # `:`ssh-ed448"`
        :public_key.generate_key({:namedCurve, :ed448})
      ]
    end)
  end

  defp default_host_key(algorithm, daemon_options) do
    host_keys =
      daemon_options
      |> Keyword.fetch!(:key_cb_private)
      |> Keyword.fetch!(:host_keys)

    host_keys
    |> Enum.find(&(algorithm in &1.algorithms))
    |> case do
      nil -> {:error, :unsupported_algorithm}
      %{key: host_key} -> {:ok, host_key}
    end
  end

  defp to_host_key_maps(host_keys) do
    Enum.map(host_keys, fn
      {:RSAPrivateKey, _, mod, exp, _, _, _, _, _, _, _} = host_key ->
        %{
          key: host_key,
          algorithms: [:"rsa-sha2-256", :"rsa-sha2-512"],
          fingerprint: :ssh.hostkey_fingerprint({:RSAPublicKey, mod, exp})
        }

      {:ECPrivateKey, _, _, {:namedCurve, curve_oid}, public_key, _} = host_key ->
        algorithm = algorithm_for_curve_oid(curve_oid)
        fingerprint = :ssh.hostkey_fingerprint({{:ECPoint, public_key}, {:namedCurve, curve_oid}})

        %{
          key: host_key,
          algorithms: [algorithm],
          fingerprint: fingerprint
        }

      other ->
        raise ArgumentError,
              "expected :host_keys to contain supported private keys, got: #{inspect(other)}"
    end)
  end

  defp algorithm_for_curve_oid({1, 3, 101, 112}), do: :"ssh-ed25519"
  defp algorithm_for_curve_oid({1, 3, 101, 113}), do: :"ssh-ed448"

  defp algorithm_for_curve_oid(curve_oid) do
    case :public_key.oid2ssh_curvename(curve_oid) do
      "nistp256" -> :"ecdsa-sha2-nistp256"
      "nistp384" -> :"ecdsa-sha2-nistp384"
      "nistp521" -> :"ecdsa-sha2-nistp521"
    end
  end

  defp default_is_auth_key(public_key, user, daemon_options) do
    user = to_string(user)

    daemon_options
    |> Keyword.fetch!(:key_cb_private)
    |> Keyword.fetch!(:auth_keys)
    |> Enum.any?(fn
      {nil, ^public_key} -> true
      {^user, ^public_key} -> true
      {_user, _public_key} -> false
    end)
  end

  defp normalize_user_passwords(options) do
    case Keyword.has_key?(options, :user_passwords) do
      true ->
        Keyword.put(
          options,
          :user_passwords,
          Enum.map(options[:user_passwords], fn {user, pass} ->
            {to_charlist(user), to_charlist(pass)}
          end)
        )

      false ->
        options
    end
  end

  defp put_subsystems(daemon_options, instance, options) do
    subsystems = Keyword.get(options, :subsystems, [])

    validate_subsystems!(subsystems)

    subsystems
    |> Enum.map(fn name ->
      {String.to_charlist(name), {Channel, [instance: instance, subsystem: name]}}
    end)
    |> case do
      [] ->
        daemon_options

      subsystems ->
        Keyword.update(daemon_options, :subsystems, subsystems, &(subsystems ++ &1))
    end
  end

  defp validate_subsystems!(subsystems) when is_list(subsystems) do
    case Enum.all?(subsystems, &(is_binary(&1) and &1 != "")) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "expected :subsystems to be a list of non-empty strings, got: #{inspect(subsystems)}"
    end
  end

  defp validate_subsystems!(subsystems) do
    raise ArgumentError, "expected :subsystems to be a list, got: #{inspect(subsystems)}"
  end

  # SSH traps exits so we must ensure we stop it explicitly when the instance
  # dies.
  defp stop_on_exit(options) do
    spawn_link(fn ->
      Process.flag(:trap_exit, true)

      receive do
        {:EXIT, _pid, _reason} -> stop(options)
      end
    end)
  end

  @ssh_log_filter __MODULE__

  # This installs a global filter to control SSH log messages, as there is no
  # way to configure `:ssh` log level directly.
  defp install_ssh_log_filter do
    %{filters: filters} = :logger.get_primary_config()

    case List.keymember?(filters, @ssh_log_filter, 0) do
      true ->
        :ok

      false ->
        :logger.add_primary_filter(
          @ssh_log_filter,
          {
            fn
              %{meta: %{test_server_ssh_log_level: process_level}, level: level}, _extra ->
                cond do
                  process_level == :none -> :stop
                  process_level == :all -> :ignore
                  Logger.compare_levels(level, process_level) == :lt -> :stop
                  true -> :ignore
                end

              _event, _extra ->
                :ignore
            end,
            []
          }
        )
    end
  end

  @doc false
  @spec stop(keyword()) :: :ok
  def stop(options) do
    daemon_pid = Keyword.fetch!(options, :daemon)

    :ssh.stop_daemon(daemon_pid)
  end
end
