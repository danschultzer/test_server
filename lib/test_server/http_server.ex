defmodule TestServer.HTTPServer do
  @moduledoc """
  HTTP server adapter module.

  ## Usage

      defmodule MyApp.MyHTTPServer do
        @behaviour TestServer.HTTPServer

        @impl true
        def start(instance, port, scheme, tls_options, server_options) do
          # ...
        end

        def stop(instance, server_options) do
          # ...
        end

        def get_socket_pid(conn) do
          # ...
        end
      end
  """
  @type scheme :: :http | :https
  @type instance :: pid()
  @type port_number :: :inet.port_number()
  @type options :: [tls: keyword(), ipfamily: :inet | :inet6]
  @type server_options :: keyword()

  @callback start(instance(), port_number(), scheme(), options(), server_options()) ::
              {:ok, pid(), server_options()} | {:error, any()}
  @callback stop(instance(), server_options()) :: :ok | {:error, any()}
  @callback get_socket_pid(Plug.Conn.t()) :: pid()

  @default_http_server Enum.find_value(
                         [
                           {Bandit, TestServer.HTTPServer.Bandit},
                           {Plug.Cowboy, TestServer.HTTPServer.Plug.Cowboy},
                           {:httpd, TestServer.HTTPServer.Httpd}
                         ],
                         fn {dep, module} ->
                           if Code.ensure_loaded?(dep), do: {module, []}
                         end
                       )

  @doc false
  @spec start(pid(), keyword()) :: {:ok, keyword()} | {:error, any()}
  def start(instance, options) do
    port = open_port(options)
    scheme = parse_scheme(options)
    {tls_options, x509_options} = maybe_generate_x509_suite(options, scheme)
    ip_family = Keyword.get(options, :ipfamily, :inet)
    test_server_options = [tls: tls_options, ipfamily: ip_family]

    {mod, server_options} =
      Keyword.get(
        options,
        :http_server,
        Application.get_env(:test_server, :http_server, @default_http_server)
      )

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

  defp open_port(options) do
    {port, options} =
      case Keyword.get(options, :port, 0) do
        {port, options} -> {port, options}
        port -> {port, []}
      end

    unless is_integer(port) and port >= 0 and port <= 65_535,
      do: raise("Invalid port, got: #{inspect(port)}")

    with {:ok, socket} <- :gen_tcp.listen(port, options),
         {:ok, port} <- :inet.port(socket),
         true <- :erlang.port_close(socket) do
      port
    else
      {:error, error} ->
        raise("Could not listen to port #{inspect(port)}, because: #{inspect(error)}")
    end
  end

  defp parse_scheme(options) do
    scheme = Keyword.get(options, :scheme, :http)

    unless scheme in [:http, :https], do: raise("Invalid scheme, got: #{inspect(scheme)}")

    scheme
  end

  defp maybe_generate_x509_suite(options, :https) do
    tls_opts = Keyword.get(options, :tls, [])

    case Keyword.has_key?(tls_opts, :key) || Keyword.has_key?(tls_opts, :keyfile) do
      true ->
        {tls_opts, []}

      false ->
        suite = X509.Test.Suite.new()

        {[
           key: {:RSAPrivateKey, X509.PrivateKey.to_der(suite.server_key)},
           cert: X509.Certificate.to_der(suite.valid),
           cacerts: suite.chain ++ suite.cacerts
         ], x509_suite: suite}
    end
  end

  defp maybe_generate_x509_suite(_options, :http) do
    {[], []}
  end

  @doc false
  @spec stop(keyword()) :: :ok | {:error, any()}
  def stop(options) do
    {mod, server_options} = Keyword.fetch!(options, :http_server)
    reference = Keyword.fetch!(options, :http_server_reference)

    mod.stop(reference, server_options)
  end
end
