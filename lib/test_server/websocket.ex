defmodule TestServer.WebSocket do
  @moduledoc false

  alias TestServer.Instance

  def handle_frame(frame, {{instance, _route_ref} = socket, state}) do
    case Instance.dispatch(socket, {:websocket, {:handle, frame}, state}) do
      {:ok, result} ->
        handle_reply(result, socket)

      {:error, :not_found} ->
        message =
          "#{Instance.format_instance(instance)} received an unexpected WebSocket frame"
          |> append_formatted_frame(frame)
          |> append_formatted_websocket_handlers(socket)

        reply_with_error({socket, state}, {RuntimeError.exception(message), []})

      {:error, {error, stacktrace}} ->
        reply_with_error({socket, state}, {error, stacktrace})
    end
  end

  defp reply_with_error({{instance, _route_ref}, state}, {exception, stacktrace}) do
    Instance.report_error(instance, {exception, stacktrace})

    {:reply, :ok, {:text, Exception.format(:error, exception, stacktrace)}, state}
  end

  defp append_formatted_frame(message, frame) do
    """
    #{message}:

    #{inspect(frame)}
    """
  end

  defp append_formatted_websocket_handlers(message, {instance, route_ref}) do
    websocket_handlers =
      Instance.websocket_handlers(instance)
      |> Enum.filter(&(&1.route_ref == route_ref))
      |> Enum.split_with(&Instance.active_websocket_handler?/1)

    """
    #{message}

    #{format_websocket_handlers(websocket_handlers)}
    """
  end

  defp format_websocket_handlers({[], exhausted_websocket_handlers}) do
    message = "No active websocket handlers."

    case exhausted_websocket_handlers do
      [] ->
        message

      websocket_handlers ->
        """
        #{message} The following websocket handlers have been processed:

        #{Instance.format_websocket_handlers(websocket_handlers)}"
        """
    end
  end

  defp format_websocket_handlers({active_websocket_handlers, _}) do
    """
    Active websocket handlers:

    #{Instance.format_websocket_handlers(active_websocket_handlers)}
    """
  end

  defp handle_reply({:reply, frame, state}, socket), do: {:reply, :ok, frame, {socket, state}}
  defp handle_reply({:ok, state}, socket), do: {:ok, {socket, state}}

  def handle_info({callback, stacktrace}, {socket, state}) do
    case Instance.dispatch(socket, {:websocket, {:info, callback, stacktrace}, state}) do
      {:ok, result} -> handle_reply(result, socket)
      {:error, {error, stacktrace}} -> reply_with_error({socket, state}, {error, stacktrace})
    end
  end
end
