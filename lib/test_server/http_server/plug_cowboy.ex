if Code.ensure_loaded?(Plug.Cowboy) do
  defmodule TestServer.HTTPServer.Plug.Cowboy do
    @moduledoc false

    # Server

    @behaviour TestServer.HTTPServer
    @behaviour :cowboy_websocket

    alias Plug.{Cowboy, Cowboy.Handler}
    alias TestServer.WebSocket

    @default_protocol_options [
      idle_timeout: :timer.seconds(1),
      request_timeout: :timer.seconds(1)
    ]

    @impl TestServer.HTTPServer
    def start(instance, port, scheme, options, cowboy_options) do
      cowboy_options =
        cowboy_options
        |> Keyword.put_new(:protocol_options, @default_protocol_options)
        |> Keyword.put(:port, port)
        |> Keyword.put(:dispatch, dispatch(instance))
        |> Keyword.put(:ref, cowboy_ref(port))
        |> Keyword.put(:net, options[:ipfamily])
        |> put_tls_options(scheme, options[:tls])

      case apply(Cowboy, scheme, [TestServer.Plug, {__MODULE__, %{}, instance}, cowboy_options]) do
        {:ok, pid} -> {:ok, pid, cowboy_options}
        {:error, error} -> {:error, error}
      end
    end

    defp dispatch(instance) do
      dispatches = [{:_, __MODULE__, {TestServer.Plug, {__MODULE__, %{}, instance}}}]

      [{:_, dispatches}]
    end

    defp put_tls_options(cowboy_options, :http, _tls_options), do: cowboy_options

    defp put_tls_options(cowboy_options, :https, tls_options) do
      Keyword.merge(cowboy_options, Keyword.put_new(tls_options, :log_level, :warning))
    end

    @impl TestServer.HTTPServer
    def stop(_pid, cowboy_options) do
      port = Keyword.fetch!(cowboy_options, :port)

      Cowboy.shutdown(cowboy_ref(port))
    end

    defp cowboy_ref(port) when is_integer(port) do
      {__MODULE__, port}
    end

    @impl TestServer.HTTPServer
    def get_socket_pid(%{adapter: {_, req}}), do: req.pid

    # Dispatch handling

    @impl :cowboy_websocket
    def init(req, {plug, instance}) do
      req
      |> Handler.init({plug, instance})
      |> case do
        {:ok, req, opts} ->
          {:ok, req, opts}

        {Plug.Cowboy.Handler, req, {_http_server, {socket, state}}, _} ->
          {:cowboy_websocket, req, {socket, state}}
      end
    end

    # WebSocket callbacks

    @impl :cowboy_websocket
    def websocket_init({socket, state}) do
      {:ok, {socket, state}}
    end

    @impl :cowboy_websocket
    def websocket_handle(frame, {socket, state}) do
      frame
      |> WebSocket.handle_frame({socket, state})
      |> handle_reply()
    end

    @impl :cowboy_websocket
    def websocket_info({callback, stacktrace}, {socket, state}) do
      {callback, stacktrace}
      |> WebSocket.handle_info({socket, state})
      |> handle_reply()
    end

    defp handle_reply({:reply, :ok, frame, state}), do: {:reply, frame, state}
    defp handle_reply(any), do: any
  end
end
