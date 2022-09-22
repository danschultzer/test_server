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
        message =
          "Unexpected message received for WebSocket"
          |> append_formatted_frame(frame)
          |> append_formatted_websocket_handlers(socket)

        reply_with_error({socket, state}, {RuntimeError.exception(message), []})

      {:error, {error, stacktrace}} ->
        reply_with_error({socket, state}, {error, stacktrace})
    end
  end

  defp reply_with_error({{instance, _route_ref}, state}, {exception, stacktrace}) do
    Instance.report_error(instance, {exception, stacktrace})

    {:reply, {:text, Exception.format(:error, exception, stacktrace)}, state}
  end

  defp append_formatted_frame(message, frame) do
    """
    #{message} with frame:

    #{inspect(frame)}
    """
  end

  defp append_formatted_websocket_handlers(message, {instance, route_ref}) do
    websocket_handlers =
      Instance.websocket_handlers(instance)
      |> Enum.filter(&(&1.route_ref == route_ref))
      |> Enum.split_with(&(not &1.suspended))

    """
    #{message}

    #{format_websocket_handlers(websocket_handlers, instance)}
    """
  end

  defp format_websocket_handlers({[], suspended_websocket_handlers}, instance) do
    message = "No active websocket handlers for #{inspect(Instance)} #{inspect(instance)}."

    case suspended_websocket_handlers do
      [] ->
        message

      websocket_handlers ->
        """
        #{message} The following websocket handler(s) have been processed:

        #{Instance.format_routes(websocket_handlers)}"
        """
    end
  end

  defp format_websocket_handlers({active_websocket_handlers, _}, instance) do
    """
    Active websocket handler(s) #{inspect(Instance)} #{inspect(instance)}:

    #{Instance.format_websocket_handlers(active_websocket_handlers)}
    """
  end

  defp handle_reply({:reply, frame, state}, socket), do: {:reply, frame, {socket, state}}
  defp handle_reply({:ok, state}, socket), do: {:ok, {socket, state}}

  @impl true
  def websocket_info({callback, stacktrace}, {socket, state}) do
    case Instance.dispatch(socket, {:websocket, {:info, callback, stacktrace}, state}) do
      {:ok, result} -> handle_reply(result, socket)
      {:error, {error, stacktrace}} -> reply_with_error({socket, state}, {error, stacktrace})
    end
  end
end
