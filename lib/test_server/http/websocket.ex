defmodule TestServer.HTTP.WebSocket do
  @moduledoc false

  alias TestServer.HTTP.Instance

  def handle_frame(frame, {instance, websocket_ref, state}) do
    case Instance.dispatch(instance, {:websocket, {:handle, websocket_ref, frame, state}}) do
      {:ok, result} ->
        handle_reply(result, instance, websocket_ref)

      {:error, :not_found} ->
        message =
          "#{TestServer.format_instance(TestServer.HTTP, instance)} received an unexpected WebSocket frame"
          |> append_formatted_frame(frame)
          |> append_formatted_websocket_handlers(instance, websocket_ref)

        reply_with_error({instance, websocket_ref, state}, {RuntimeError.exception(message), []})

      {:error, {error, stacktrace}} ->
        reply_with_error({instance, websocket_ref, state}, {error, stacktrace})
    end
  end

  defp reply_with_error({instance, _websocket_ref, state}, {exception, stacktrace}) do
    TestServer.report_error(Instance.options(instance), {exception, stacktrace})

    {:reply, :ok, {:text, Exception.format(:error, exception, stacktrace)}, state}
  end

  defp append_formatted_frame(message, frame) do
    """
    #{message}:

    #{inspect(frame)}
    """
  end

  defp append_formatted_websocket_handlers(message, instance, websocket_ref) do
    websocket_handlers =
      Instance.websocket_handlers(instance)
      |> Enum.filter(&(&1.websocket_ref == websocket_ref))
      |> Enum.split_with(&(not &1.suspended))

    """
    #{message}

    #{format_websocket_handlers(websocket_handlers)}
    """
  end

  defp format_websocket_handlers({[], suspended_websocket_handlers}) do
    message = "No active websocket handlers."

    case suspended_websocket_handlers do
      [] ->
        message

      websocket_handlers ->
        """
        #{message} The following websocket handlers have been processed:

        #{Instance.format_websocket_handlers(websocket_handlers)}
        """
    end
  end

  defp format_websocket_handlers({active_websocket_handlers, _}) do
    """
    Active websocket handlers:

    #{Instance.format_websocket_handlers(active_websocket_handlers)}
    """
  end

  defp handle_reply({:reply, frame, state}, instance, websocket_ref),
    do: {:reply, :ok, frame, {instance, websocket_ref, state}}

  defp handle_reply({:ok, state}, instance, websocket_ref),
    do: {:ok, {instance, websocket_ref, state}}

  def handle_info({:send, {options, stacktrace}}, {instance, websocket_ref, state}) do
    case Instance.dispatch(
           instance,
           {:websocket, {:send, websocket_ref, options, state, stacktrace}}
         ) do
      {:ok, result} ->
        handle_reply(result, instance, websocket_ref)

      {:error, {error, stacktrace}} ->
        reply_with_error({instance, websocket_ref, state}, {error, stacktrace})
    end
  end
end
