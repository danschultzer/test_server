defmodule TestServer.SSH.Channel do
  @moduledoc false

  @behaviour :ssh_server_channel

  alias TestServer.SSH.Instance

  defstruct [:instance, :channel, :state]

  @impl true
  def init(options) do
    {:ok, %__MODULE__{instance: Keyword.fetch!(options, :instance), state: %{}}}
  end

  @impl true
  def handle_msg({:EXIT, _pid, _reason}, state) do
    {:stop, state.channel.channel_id, state}
  end

  def handle_msg({:ssh_channel_up, channel_id, connection}, state) do
    case Instance.dispatch(state.instance, {:channel_up, channel_id, connection}) do
      {:ok, channel} ->
        {:ok, %{state | channel: channel}}

      {:error, :not_found} ->
        message =
          append_formatted_channels(
            "#{TestServer.format_instance(TestServer.SSH, state.instance)} received an unexpected SSH channel up message for channel ID #{channel_id} on connection #{inspect(connection)}.",
            state.instance
          )

        send_error(connection, channel_id, {RuntimeError.exception(message), []}, state)

        {:stop, channel_id, state}
    end
  end

  defp append_formatted_channels(message, instance) do
    channels = Enum.split_with(Instance.channels(instance), &is_nil(&1.channel_id))

    """
    #{message}

    #{format_channels(channels)}
    """
  end

  defp format_channels({[], used_channels}) do
    message = "No available channels."

    case used_channels do
      [] ->
        message

      used_channels ->
        """
        #{message} The following channels have been used:

        #{Instance.format_channels(used_channels)}
        """
    end
  end

  defp format_channels({available_channels, _used_channels}) do
    """
    Available channels:

    #{Instance.format_channels(available_channels)}
    """
  end

  defp send_error(connection, channel_id, {exception, stacktrace}, state) do
    Instance.report_error(state.instance, {exception, stacktrace})

    message = Exception.format(:error, exception, stacktrace)

    :ssh_connection.send(connection, channel_id, message)
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, connection, frame}, state) do
    type = elem(frame, 0)
    messages = Keyword.fetch!(state.channel.options, :messages)

    case dispatch(messages, type, connection, frame, state) do
      {:raw, {:ok, channel_state}} ->
        {:ok, %{state | state: channel_state}}

      {:raw, {:stop, channel_id, channel_state}} ->
        {:stop, channel_id, %{state | state: channel_state}}

      response ->
        respond(response, connection, frame, state)
    end
  end

  defp dispatch(messages, type, connection, frame, state) do
    case messages == :all or type in messages do
      true ->
        Instance.dispatch(
          state.instance,
          {:handle, state.channel.ref, connection, frame, state.state}
        )

      false ->
        {:ok, state.state}
    end
  end

  defp respond(response, connection, frame, state) do
    type = elem(frame, 0)
    channel_id = elem(frame, 1)

    %{
      type: type,
      channel_id: channel_id,
      connection: connection,
      frame: frame,
      state: state
    }
    |> acknowledge()
    |> send_response(response)
    |> finish(response)
  end

  defp acknowledge(
         %{
           type: type,
           channel_id: channel_id,
           connection: connection,
           frame: frame
         } = reply
       )
       when type in ~w(exec env pty shell subsystem)a do
    want_reply = elem(frame, 2)

    :ssh_connection.reply_request(connection, want_reply, :success, channel_id)

    reply
  end

  defp acknowledge(
         %{
           type: :data,
           channel_id: channel_id,
           connection: connection,
           frame: {:data, _channel_id, _want_reply, data}
         } = reply
       ) do
    :ssh_connection.adjust_window(connection, channel_id, byte_size(data))

    reply
  end

  defp acknowledge(
         %{
           type: type,
           channel_id: _channel_id,
           connection: _connection,
           frame: _frame
         } = reply
       )
       when type in ~w(eof closed signal window_change)a, do: reply

  defp send_response(
         %{
           connection: _connection,
           channel_id: _channel_id,
           state: state
         } = reply,
         {:ok, channel_state}
       ) do
    %{reply | state: %{state | state: channel_state}}
  end

  defp send_response(
         %{
           connection: connection,
           channel_id: channel_id,
           state: state
         } = reply,
         {:reply, {data, options}, channel_state}
       ) do
    data_type_code = Keyword.get(options, :data_type_code, 0)

    :ssh_connection.send(connection, channel_id, data_type_code, data)

    %{reply | state: %{state | state: channel_state}}
  end

  defp send_response(
         %{
           connection: connection,
           channel_id: channel_id,
           frame: frame,
           state: state
         } = reply,
         {:error, :not_found}
       ) do
    message =
      "#{TestServer.format_instance(TestServer.SSH, state.instance)} received an unexpected SSH message"
      |> append_formatted_frame(frame)
      |> append_formatted_handlers(state.instance)

    send_error(connection, channel_id, {RuntimeError.exception(message), []}, state)

    reply
  end

  defp send_response(
         %{
           connection: connection,
           channel_id: channel_id,
           frame: _frame,
           state: state
         } = reply,
         {:error, {exception, stacktrace}}
       ) do
    send_error(connection, channel_id, {exception, stacktrace}, state)

    reply
  end

  defp append_formatted_frame(message, frame) do
    """
    #{message}:

    #{inspect(frame)}
    """
  end

  defp append_formatted_handlers(message, instance) do
    handlers = Enum.split_with(Instance.handlers(instance), &(not &1.suspended))

    """
    #{message}

    #{format_handlers(handlers)}
    """
  end

  defp format_handlers({[], suspended_handlers}) do
    message = "No active handlers."

    case suspended_handlers do
      [] ->
        message

      suspended_handlers ->
        """
        #{message} The following handlers have been processed:

        #{Instance.format_handlers(suspended_handlers)}
        """
    end
  end

  defp format_handlers({active_handlers, _suspended_handlers}) do
    """
    Active handlers:

    #{Instance.format_handlers(active_handlers)}
    """
  end

  defp finish(
         %{
           connection: connection,
           frame: {:exec, channel_id, _want_reply, _command},
           state: state
         },
         response
       ) do
    exit_status =
      case response do
        {:reply, {_data, options}, _channel_state} -> Keyword.get(options, :exit_status, 0)
        _other -> 0
      end

    :ssh_connection.exit_status(connection, channel_id, exit_status)
    :ssh_connection.send_eof(connection, channel_id)
    :ssh_connection.close(connection, channel_id)

    {:stop, channel_id, state}
  end

  defp finish(
         %{
           connection: _,
           frame: {:closed, channel_id},
           state: state
         },
         _response
       ),
       do: {:stop, channel_id, state}

  defp finish(
         %{
           connection: _,
           frame: _,
           state: state
         },
         _response
       ),
       do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
