if Code.ensure_loaded?(Plug.Cowboy) do
  defmodule TestServer.HTTP.Server.Plug.Cowboy do
    @moduledoc """
    HTTP server adapter using `Plug.Cowboy`.

    By default only one acceptor process is started which is enough for
    testing. This adapter will be used by default if `Bandit` is not loaded
    and `Plug.Cowboy` is loaded in the project.

    ## Usage

        TestServer.HTTP.start!(
          http_server: {TestServer.HTTP.Server.Plug.Cowboy, cowboy_options}
        )
    """

    # Server

    @behaviour TestServer.HTTP.Server
    @behaviour :cowboy_websocket

    alias Plug.{Cowboy, Cowboy.Handler}
    alias TestServer.HTTP.WebSocket

    @default_protocol_options [
      idle_timeout: :timer.seconds(1),
      request_timeout: :timer.seconds(1)
    ]

    @impl TestServer.HTTP.Server
    def start(instance, port, scheme, options, cowboy_options) do
      tls_options =
        options
        |> Keyword.get(:tls, [])
        |> Keyword.put_new(:log_level, :warning)

      cowboy_options =
        [
          ip: Keyword.get(options, :ip),
          net: Keyword.get(options, :ipfamily)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Keyword.merge(cowboy_options)
        |> Keyword.put(:port, port)
        |> Keyword.put(:dispatch, dispatch(instance))
        |> Keyword.put(:ref, instance)
        |> Keyword.put_new(:protocol_options, @default_protocol_options)
        # For tests it is not necessary to open the default 100 acceptor
        # processes
        |> Keyword.put_new(:transport_options, num_acceptors: 1)
        |> put_tls_options(scheme, tls_options)

      case apply(Cowboy, scheme, [
             TestServer.HTTP.Plug,
             {__MODULE__, %{}, instance},
             cowboy_options
           ]) do
        {:ok, server_pid} ->
          address = :ranch.get_addr(instance)

          {:ok, server_pid, address, cowboy_options, fn _ -> Cowboy.shutdown(instance) end}

        {:error, error} ->
          {:error, error}
      end
    end

    defp dispatch(instance) do
      dispatches = [{:_, __MODULE__, {TestServer.HTTP.Plug, {__MODULE__, %{}, instance}}}]

      [{:_, dispatches}]
    end

    defp put_tls_options(cowboy_options, :http, _tls_options), do: cowboy_options

    defp put_tls_options(cowboy_options, :https, tls_options),
      do: Keyword.merge(cowboy_options, tls_options)

    @impl TestServer.HTTP.Server
    def socket_pid(%{adapter: {_, req}}), do: req.pid

    # Dispatch handling

    @impl :cowboy_websocket
    def init(req, {plug, instance}) do
      req
      |> Handler.init({plug, instance})
      |> case do
        {:ok, req, options} ->
          {:ok, req, options}

        {Plug.Cowboy.Handler, req, {_http_server, {instance, websocket_ref, state}}, _} ->
          {:cowboy_websocket, req, {instance, websocket_ref, state}}
      end
    end

    # WebSocket callbacks

    @impl :cowboy_websocket
    def websocket_init({instance, websocket_ref, state}) do
      {:ok, {instance, websocket_ref, state}}
    end

    @impl :cowboy_websocket
    def websocket_handle(frame, state) when frame in [:ping, :pong],
      do: {:ok, state}

    def websocket_handle({opcode, _payload}, state) when opcode in [:ping, :pong],
      do: {:ok, state}

    def websocket_handle(frame, {instance, websocket_ref, state}) do
      frame
      |> WebSocket.handle_frame({instance, websocket_ref, state})
      |> handle_reply()
    end

    @impl :cowboy_websocket
    def websocket_info({:send, {options, stacktrace}}, {instance, websocket_ref, state}) do
      {:send, {options, stacktrace}}
      |> WebSocket.handle_info({instance, websocket_ref, state})
      |> handle_reply()
    end

    defp handle_reply({:reply, :ok, frame, state}), do: {:reply, frame, state}
    defp handle_reply(any), do: any
  end
end
