defmodule TestServer.Plug.Cowboy.Handler do
  @moduledoc false

  alias Plug.Cowboy.Handler
  alias TestServer.Instance

  @behaviour :cowboy_websocket

  @impl true
  def init(req, {plug, instance}) do
    req
    |> Handler.init({plug, instance})
    |> maybe_init_websocket()
  end

  defp maybe_init_websocket({:ok, {:websocket, req, {socket, state}}, {_plug, _instance}}) do
    :ok = Instance.put_websocket_connection(socket, req)

    {:cowboy_websocket, req, {socket, state}}
  end

  defp maybe_init_websocket({:ok, req, opts}) do
    {:ok, req, opts}
  end

  # WebSocket callbacks

  @impl true
  def websocket_init({socket, state}) do
    {:ok, {socket, state}}
  end

  @impl true
  def websocket_handle(frame, {socket, state}) do
    case Instance.dispatch(socket, {:websocket, {:handle, frame}, state}) do
      {:ok, result} ->
        handle_reply(result, socket)

      {:error, :not_found} ->
        message = """
        Unexpected message received for WebSocket.

        Frame:
        #{inspect(frame)}

        #{format_active_websocket_handlers(socket)}
        """

        reply_with_error({socket, state}, {RuntimeError.exception(message), []})

      {:error, {error, stacktrace}} ->
        reply_with_error({socket, state}, {error, stacktrace})
    end
  end

  defp reply_with_error({{instance, _route_ref}, state}, {exception, stacktrace}) do
    Instance.report_error(instance, {exception, stacktrace})

    {:reply, {:text, Exception.format(:error, exception, stacktrace)}, state}
  end

  defp format_active_websocket_handlers({instance, route_ref}) do
    active_websocket_handlers =
      Enum.filter(
        Instance.websocket_handlers(instance),
        &(not &1.suspended and &1.route_ref == route_ref)
      )

    format_active_websocket_handlers(active_websocket_handlers)
  end

  defp format_active_websocket_handlers([]),
    do: "\n\nNo active websocket handlers"

  defp format_active_websocket_handlers(active_websocket_handlers) do
    "\n\nActive websocket handler(s):\n\n#{Instance.format_websocket_handlers(active_websocket_handlers)}"
  end

  defp handle_reply({:reply, frame, state}, socket), do: {:reply, frame, {socket, state}}
  defp handle_reply({:ok, state}, socket), do: {:ok, {socket, state}}

  @impl true
  def websocket_info({options, stacktrace}, {socket, state}) do
    case Instance.dispatch(socket, {:websocket, {:info, options, stacktrace}, state}) do
      {:ok, result} -> handle_reply(result, socket)
      {:error, {error, stacktrace}} -> reply_with_error({socket, state}, {error, stacktrace})
    end
  end
end
