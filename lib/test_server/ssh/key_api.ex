defmodule TestServer.SSH.KeyAPI do
  @moduledoc false

  @behaviour :ssh_server_key_api

  alias TestServer.SSH.Instance

  @impl true
  def host_key(algorithm, daemon_options) do
    host_key = Keyword.fetch!(daemon_options[:key_cb_private], :host_key)

    case algorithm do
      :"rsa-sha2-256" -> {:ok, host_key}
      :"rsa-sha2-512" -> {:ok, host_key}
      :ssh_rsa -> {:ok, host_key}
      _ -> {:error, :unsupported_algorithm}
    end
  end

  @impl true
  def is_auth_key(public_key, _user, daemon_options) do
    instance = Keyword.fetch!(daemon_options[:key_cb_private], :instance)
    credentials = get_credentials(instance)

    Enum.any?(credentials, &credential_matches_public_key?(&1, public_key))
  end

  defp get_credentials(instance) do
    instance
    |> Instance.get_options()
    |> Keyword.get(:credentials, [])
  end

  defp credential_matches_public_key?({_user, {:public_key, pem}}, public_key) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        entry
        |> :public_key.pem_entry_decode()
        |> decode_public_key()
        |> Kernel.==(public_key)

      _ ->
        false
    end
  end

  defp credential_matches_public_key?(_, _), do: false

  defp decode_public_key({:RSAPrivateKey, _, modulus, public_exponent, _, _, _, _, _, _, _}),
    do: {:RSAPublicKey, modulus, public_exponent}

  defp decode_public_key(key), do: key
end
