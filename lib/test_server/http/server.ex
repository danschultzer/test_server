defmodule TestServer.HTTP.Server do
  @moduledoc """
  HTTP server adapter behaviour.

  Defines the behaviour for custom HTTP server adapters used by `TestServer.HTTP`.

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
            {:ok, server_pid} ->
              {:ok, server_pid, my_http_server_options, &MyHTTPServer.stop/1}

            {:error, error} ->
              {:error, error}
          end
        end

        @impl TestServer.HTTP.Server
        def socket_pid(%{adapter: {_, data}}), do: data.pid # Or however your adapter provides the pid
      end
  """
  @type scheme :: :http | :https
  @type port_number :: :inet.port_number()
  @type options :: [tls: keyword(), ipfamily: :inet | :inet6]
  @type server_options :: keyword()
  @type on_exit :: (server_pid :: pid() -> :ok)

  @callback start(TestServer.instance(), port_number(), scheme(), options(), server_options()) ::
              {:ok, term(), server_options(), on_exit()} | {:error, term()}
  @callback socket_pid(Plug.Conn.t()) :: pid()

  @doc false
  @spec start(TestServer.instance(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def start(instance, options) do
    scheme = validate_scheme!(options)
    options = put_tls_options(options, scheme)
    ip_family = Keyword.get(options, :ipfamily, :inet)
    test_server_options = [tls: Keyword.get(options, :tls, []), ipfamily: ip_family]
    {mod, server_options} = http_server(options)

    with {:ok, port} <- TestServer.open_port(options),
         {:ok, server_pid, server_options, on_exit_fn} <-
           mod.start(instance, port, scheme, test_server_options, server_options) do
      :ok = TestServer.supervise_server(server_pid, on_exit_fn)

      options =
        options
        |> Keyword.put(:scheme, scheme)
        |> Keyword.put(:port, port)
        |> Keyword.put(:http_server, {mod, server_options})
        |> Keyword.put(:server, server_pid)

      {:ok, options}
    end
  end

  defp validate_scheme!(options) do
    scheme = Keyword.get(options, :scheme, :http)

    case scheme in [:http, :https] do
      true ->
        scheme

      false ->
        raise ArgumentError, "expected :scheme to be :http or :https, got: #{inspect(scheme)}"
    end
  end

  defp put_tls_options(options, :https), do: TestServer.put_tls_options(options)
  defp put_tls_options(options, :http), do: options

  defp http_server(options) do
    case options[:http_server] || Application.get_env(:test_server, :http_server) ||
           default_http_server() do
      {mod, server_options} when is_atom(mod) and is_list(server_options) ->
        {mod, server_options}

      other ->
        raise ArgumentError,
              "expected :http_server to be a {module, options} tuple, got: #{inspect(other)}"
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
end
