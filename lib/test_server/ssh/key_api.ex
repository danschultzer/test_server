defmodule TestServer.SSH.KeyAPI do
  @moduledoc false

  @behaviour :ssh_server_key_api

  alias TestServer.SSH.Instance

  @impl true
  def host_key(algorithm, daemon_options) do
    key_cb_options = daemon_options[:key_cb_private]
    host_key = key_cb_options[:host_key]

    case algorithm do
      :"rsa-sha2-256" -> {:ok, host_key}
      :"rsa-sha2-512" -> {:ok, host_key}
      :ssh_rsa -> {:ok, host_key}
      _ -> {:error, :unsupported_algorithm}
    end
  end

  @impl true
  def is_auth_key(public_key, _user, daemon_options) do
    key_cb_options = daemon_options[:key_cb_private]
    instance = key_cb_options[:instance]

    check_public_key(instance, public_key)
  end

  defp check_public_key(instance, public_key) do
    credentials = get_credentials(instance)

    Enum.any?(credentials, fn
      {_user, {:public_key, pem}} when is_binary(pem) ->
        case :public_key.pem_decode(pem) do
          [entry | _] ->
            decoded_key = :public_key.pem_entry_decode(entry)
            extract_public_key(decoded_key) == public_key

          _ ->
            false
        end

      _ ->
        false
    end)
  end

  defp get_credentials(instance) do
    instance
    |> Instance.get_options()
    |> Keyword.get(:credentials, [])
  end

  defp extract_public_key({:RSAPrivateKey, _, modulus, public_exponent, _, _, _, _, _, _, _}) do
    {:RSAPublicKey, modulus, public_exponent}
  end

  defp extract_public_key(public_key), do: public_key
end
