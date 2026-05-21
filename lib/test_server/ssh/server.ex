defmodule TestServer.SSH.Server do
  @moduledoc false

  @doc false
  @spec start(pid(), keyword()) :: {:ok, keyword()} | {:error, any()}
  def start(instance, options) do
    port = TestServer.open_port(options)
    {host_keys, daemon_options} = daemon_options(instance, options)

    case :ssh.daemon(port, daemon_options) do
      {:ok, daemon_ref} ->
        suppress_ssh_strict_kex_ordering_log?(options) && install_strict_kex_filter()

        options =
          options
          |> Keyword.put(:host_keys, host_keys)
          |> Keyword.put(:port, port)
          |> Keyword.put(:daemon_ref, daemon_ref)

        {:ok, options}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp daemon_options(instance, options) do
    tmp_dir = to_charlist(System.tmp_dir!())

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
          auth_keys: auth_keys
        ]
      }

    ssh_cli =
      {
        TestServer.SSH.Channel,
        options
        |> Keyword.take([:listen])
        |> Keyword.put(:instance, instance)
      }

    daemon_options =
      options
      |> Keyword.take([:auth_methods, :no_auth_needed, :user_passwords])
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
      |> Keyword.merge(Keyword.get(options, :daemon, []))

    daemon_options =
      case Keyword.get(options, :ipfamily, :inet) do
        :inet -> daemon_options
        ipfamily -> [ipfamily | daemon_options]
      end

    {host_keys, daemon_options}
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
        raise "Unsupported host key format: #{inspect(other)}"
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

  defp suppress_ssh_strict_kex_ordering_log?(options),
    do: Keyword.get(options, :suppress_ssh_strict_kex_ordering_log, true)

  @ssh_strict_kex_filter :test_server_suppress_ssh_strict_kex_ordering

  # Erlang's ssh_transport module logs "server will use strict KEX ordering" at debug
  # level using logger:debug/1 (bare string, no metadata). Because there's no module
  # metadata, set_module_level/set_application_level can't target it. We use a primary
  # filter that drops this specific debug message.
  defp install_strict_kex_filter do
    %{filters: filters} = :logger.get_primary_config()

    unless List.keyfind(filters, @ssh_strict_kex_filter, 0) do
      :logger.add_primary_filter(@ssh_strict_kex_filter, {
        fn
          %{level: :debug, msg: {:string, ~c"server will use strict KEX ordering"}}, _extra ->
            :stop

          _event, _extra ->
            :ignore
        end,
        []
      })
    end
  end

  @doc false
  @spec stop(keyword()) :: :ok
  def stop(options) do
    daemon_ref = Keyword.fetch!(options, :daemon_ref)

    try do
      :ssh.stop_daemon(daemon_ref)
    after
      suppress_ssh_strict_kex_ordering_log?(options) &&
        :logger.remove_primary_filter(@ssh_strict_kex_filter)
    end
  end
end
