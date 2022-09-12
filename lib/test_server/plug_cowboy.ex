defmodule TestServer.Plug.Cowboy do
  @moduledoc false

  @behaviour Application

  alias TestServer
  alias TestServer.Instance
  alias Plug.{Conn, Cowboy}

  @default_protocol_options [
    idle_timeout: :timer.seconds(1),
    request_timeout: :timer.seconds(1)
  ]

  @impl true
  def start(instance, options) do
    port = open_port(options)
    scheme = Keyword.get(options, :scheme, :http)

    unless scheme in [:http, :https], do: raise("Invalid scheme, got: #{inspect(scheme)}")

    options =
      options
      |> Keyword.put_new(:port, port)
      |> Keyword.put_new(:scheme, scheme)
      |> set_cowboy_options()

    plug_cowboy_options =
      options
      |> Keyword.fetch!(:cowboy_options)
      |> Keyword.put(:port, port)
      |> Keyword.put(:ref, cowboy_ref(port))

    case apply(Cowboy, scheme, [__MODULE__.Plug, [instance], plug_cowboy_options]) do
      {:ok, cowboy} -> {:ok, cowboy, options}
      {:error, error} -> {:error, error}
    end
  end

  defp open_port(options) do
    {port, options} =
      case Keyword.get(options, :port, 0) do
        {port, options} -> {port, options}
        port -> {port, []}
      end

    unless is_integer(port), do: raise("Invalid port, got: #{inspect(port)}")

    {:ok, socket} = :gen_tcp.listen(port, options)
    {:ok, port} = :inet.port(socket)
    true = :erlang.port_close(socket)

    port
  end

  @impl true
  def stop(options) do
    port = Keyword.fetch!(options, :port)

    Cowboy.shutdown(cowboy_ref(port))
  end

  defp set_cowboy_options(options) do
    cowboy_options =
      options
      |> Keyword.get(:cowboy_options, [])
      |> Keyword.put_new(:protocol_options, @default_protocol_options)

    {cowboy_ssl_options, extras} =
      maybe_generate_x509_suite(cowboy_options, Keyword.fetch!(options, :scheme))

    cowboy_options = Keyword.merge(cowboy_options, cowboy_ssl_options)

    options
    |> Keyword.put(:cowboy_options, cowboy_options)
    |> Keyword.merge(extras)
  end

  defp maybe_generate_x509_suite(cowboy_options, :https) do
    case Keyword.has_key?(cowboy_options, :key) || Keyword.has_key?(cowboy_options, :keyfile) do
      true ->
        {[], []}

      false ->
        suite = X509.Test.Suite.new()

        {[
           key: {:RSAPrivateKey, X509.PrivateKey.to_der(suite.server_key)},
           cert: X509.Certificate.to_der(suite.valid),
           cacerts: suite.chain ++ suite.cacerts
         ], x509_suite: suite}
    end
  end

  defp maybe_generate_x509_suite(_cowboy_options, :http) do
    {[], []}
  end

  defp cowboy_ref(port) when is_integer(port) do
    {__MODULE__, port}
  end

  defmodule Plug do
    @moduledoc false

    def init([instance]), do: instance

    def call(conn, instance) do
      conn = Conn.fetch_query_params(conn)

      case Instance.dispatch(instance, conn) do
        {:ok, conn} ->
          conn

        {:error, {:not_found, conn}} ->
          message =
            "Unexpected #{conn.method} request received at #{conn.request_path}"
            |> append_params(conn)
            |> format_active_routes(Instance.active_routes(instance), instance)

          resp_error(conn, instance, {RuntimeError.exception(message), []})

        {:error, {error, stacktrace}} ->
          resp_error(conn, instance, {error, stacktrace})
      end
    end

    defp append_params(message, conn) do
      conn
      |> Map.take([:query_params, :body_params])
      |> Enum.filter(fn
        {_key, %Conn.Unfetched{}} -> false
        {_key, empty} when empty == %{} -> false
        {_key, params} when is_map(params) -> true
      end)
      |> case do
        [] -> message <> "."
        params -> message <> " with params:\n\n#{inspect(Map.new(params), pretty: true)}"
      end
    end

    defp format_active_routes(message, [], instance),
      do: message <> "\n\nNo active routes for #{inspect(Instance)} #{inspect(instance)}"

    defp format_active_routes(message, active_routes, instance) do
      message <>
        "\n\nActive routes for #{inspect(Instance)} #{inspect(instance)}:\n\n#{Instance.format_routes(active_routes)}"
    end

    defp resp_error(conn, instance, {exception, stacktrace}) do
      Instance.report_error(instance, {exception, stacktrace})

      Conn.send_resp(conn, 500, Exception.format(:error, exception, stacktrace))
    end

    def default_plug, do: &Conn.fetch_query_params/1
  end
end
