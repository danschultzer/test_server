defmodule TestServer.Plug.Cowboy do
  @moduledoc false

  @behaviour Application

  alias Plug.Cowboy

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
      |> Keyword.put(:dispatch, dispatch(instance))
      |> Keyword.put(:ref, cowboy_ref(port))

    case apply(Cowboy, scheme, [__MODULE__.Plug, [instance], plug_cowboy_options]) do
      {:ok, pid} -> {:ok, pid, options}
      {:error, error} -> {:error, error}
    end
  end

  defp dispatch(instance) do
    dispatches = [{:_, __MODULE__.Handler, {__MODULE__.Plug, instance}}]

    [{:_, dispatches}]
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
end
