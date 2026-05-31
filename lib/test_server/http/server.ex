defmodule TestServer.HTTP.Server do
  @moduledoc """
  HTTP server adapter behaviour.

  ## Usage

      defmodule MyApp.MyHTTPServer do
        @behaviour TestServer.HTTP.Server

        @impl TestServer.HTTP.Server
        def start(instance, port, scheme, options, server_options) do
          my_http_server_options =
            server_options
            |> Keyword.put(:port, port)
            |> Keyword.put_new(:ipfamily, options[:ipfamily])

          case MyHTTPServer.start(my_http_server_options) do
            {:ok, server_pid} -> {:ok, server_pid, my_http_server_options}
            {:error, error} -> {:error, error}
          end
        end

        @impl TestServer.HTTP.Server
        def stop(server_pid, server_options), do: MyHTTPServer.stop(server_pid)

        @impl TestServer.HTTP.Server
        def get_socket_pid(%{adapter: {_, data}}), do: data.pid # or however your adapter provides the pid
      end
  """
  @type scheme :: :http | :https
  @type port_number :: :inet.port_number()
  @type options :: [tls: keyword(), ipfamily: :inet | :inet6]
  @type server_options :: keyword()

  @callback start(TestServer.instance(), port_number(), scheme(), options(), server_options()) ::
              {:ok, term(), server_options()} | {:error, term()}
  @callback stop(term(), server_options()) :: :ok | {:error, term()}
  @callback get_socket_pid(Plug.Conn.t()) :: pid()

  @doc false
  @spec start(TestServer.instance(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def start(instance, options) do
    port = TestServer.open_port(options)
    scheme = parse_scheme(options)
    {tls_options, x509_options} = maybe_generate_x509_suite(options, scheme)
    ip_family = Keyword.get(options, :ipfamily, :inet)
    test_server_options = [tls: tls_options, ipfamily: ip_family]
    {mod, server_options} = http_server(options)

    case mod.start(instance, port, scheme, test_server_options, server_options) do
      {:ok, reference, server_options} ->
        options =
          options
          |> Keyword.merge(x509_options)
          |> Keyword.put(:scheme, scheme)
          |> Keyword.put(:port, port)
          |> Keyword.put(:http_server, {mod, server_options})
          |> Keyword.put(:http_server_reference, reference)

        {:ok, options}

      {:error, error} ->
        {:error, error}
    end
  end

  defp parse_scheme(options) do
    scheme = Keyword.get(options, :scheme, :http)

    unless scheme in [:http, :https], do: raise("Invalid scheme, got: #{inspect(scheme)}")

    scheme
  end

  defp maybe_generate_x509_suite(options, :https) do
    tls_options = Keyword.get(options, :tls, [])

    case Keyword.take(tls_options, [:key, :keyfile]) do
      [] ->
        suite = X509.Test.Suite.new()
        server_key = X509.PrivateKey.to_der(suite.server_key)
        cert = X509.Certificate.to_der(suite.valid)

        {[
           key: {:RSAPrivateKey, server_key},
           cert: cert,
           cacerts: suite.chain ++ suite.cacerts
         ], x509_suite: %{cert: cert, cacerts: suite.cacerts}}

      [_ | _] ->
        {tls_options, []}
    end
  end

  defp maybe_generate_x509_suite(_options, :http) do
    {[], []}
  end

  defp http_server(options) do
    case options[:http_server] || Application.get_env(:test_server, :http_server) ||
           default_http_server() do
      {mod, server_options} when is_atom(mod) and is_list(server_options) -> {mod, server_options}
      other -> raise("Invalid http_server, got: #{inspect(other)}")
    end
  end

  defp default_http_server do
    cond do
      Code.ensure_loaded?(TestServer.HTTP.Server.Bandit) ->
        {TestServer.HTTP.Server.Bandit, []}

      Code.ensure_loaded?(TestServer.HTTP.Server.Plug.Cowboy) ->
        {TestServer.HTTP.Server.Plug.Cowboy, []}

      true ->
        {TestServer.HTTP.Server.Httpd, []}
    end
  end

  @doc false
  @spec stop(keyword()) :: :ok | {:error, term()}
  def stop(options) do
    {mod, server_options} = Keyword.fetch!(options, :http_server)
    reference = Keyword.fetch!(options, :http_server_reference)

    mod.stop(reference, server_options)
  end
end
