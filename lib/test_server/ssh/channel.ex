defmodule TestServer.SSH.Channel do
  @moduledoc false

  @behaviour :ssh_server_channel

  alias TestServer.SSH.Instance

  defstruct [:instance, :channel_id, :connection, :channel_ref, listen: [:exec, :data]]

  @impl true
  def init(opts) do
    listen = Keyword.get(opts, :listen, [:exec, :data])

    {:ok, %__MODULE__{instance: Keyword.fetch!(opts, :instance), listen: listen}}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, _connection, {:closed, channel_id}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, connection, inner}, state) do
    acknowledge(connection, inner)

    case maybe_dispatch(state, inner) do
      {:ok, :ignore} ->
        {:ok, state}

      {:ok, reply} ->
        send_reply(connection, state, reply)
        finish(connection, inner, reply_opts(reply), state)

      {:error, reason} ->
        handle_dispatch_error(connection, state, inner, reason)
        finish(connection, inner, [exit_status: 1], state)
    end
  end

  @impl true
  def handle_msg({:EXIT, _pid, _reason}, state) do
    {:stop, state.channel_id, state}
  end

  def handle_msg({:ssh_channel_up, channel_id, connection}, state) do
    case Instance.dispatch(state.instance, {:channel_up, connection}) do
      {:ok, channel_ref} ->
        {:ok, %{state | channel_id: channel_id, connection: connection, channel_ref: channel_ref}}

      {:error, {exception, stacktrace}} ->
        handle_error(
          connection,
          %{state | channel_id: channel_id, connection: connection},
          {exception, stacktrace}
        )

        {:stop, channel_id, state}
    end
  end

  def handle_msg(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp acknowledge(connection, {:data, channel_id, _type, data}),
    do: :ssh_connection.adjust_window(connection, channel_id, byte_size(data))

  defp acknowledge(_connection, {:eof, _channel_id}), do: :ok

  defp acknowledge(connection, inner),
    do: :ssh_connection.reply_request(connection, elem(inner, 2), :success, elem(inner, 1))

  defp maybe_dispatch(state, inner) do
    type = elem(inner, 0)

    cond do
      state.listen == :all or type in state.listen ->
        Instance.dispatch(state.instance, {:handle, inner, state.channel_ref})

      type in [:exec, :data] ->
        {:ok, {:reply, to_string(elem(inner, 3))}}

      true ->
        {:ok, :noreply}
    end
  end

  defp send_reply(connection, state, {:reply, data}),
    do: :ssh_connection.send(connection, state.channel_id, data)

  defp send_reply(connection, state, {:reply, data, opts}) do
    :ssh_connection.send(connection, state.channel_id, data)
    send_stderr(connection, state, opts)
  end

  defp send_reply(_connection, _state, :noreply), do: :ok

  defp reply_opts({:reply, _data, opts}), do: opts
  defp reply_opts(_), do: []

  defp handle_dispatch_error(connection, state, inner, :not_found),
    do: handle_not_found(connection, state, elem(inner, 0), inner)

  defp handle_dispatch_error(connection, state, _inner, {exception, stacktrace}),
    do: handle_error(connection, state, {exception, stacktrace})

  defp finish(connection, {:exec, _ch, _wr, _cmd}, opts, state) do
    :ssh_connection.exit_status(connection, state.channel_id, Keyword.get(opts, :exit_status, 0))
    :ssh_connection.send_eof(connection, state.channel_id)
    :ssh_connection.close(connection, state.channel_id)
    {:stop, state.channel_id, state}
  end

  defp finish(_connection, _inner, _opts, state), do: {:ok, state}

  defp send_stderr(connection, state, opts) do
    case Keyword.get(opts, :stderr) do
      nil -> :ok
      stderr -> :ssh_connection.send(connection, state.channel_id, 1, to_string(stderr))
    end
  end

  defp handle_not_found(connection, state, type, inner) do
    message =
      "#{TestServer.format_instance(TestServer.SSH, state.instance)} received an unexpected SSH message of type #{type}"
      |> append_formatted_input(inner)
      |> append_formatted_handlers(state.instance)

    handle_error(connection, state, {RuntimeError.exception(message), []})
  end

  defp append_formatted_input(message, inner) do
    """
    #{message}:

    #{inspect(inner)}
    """
  end

  defp append_formatted_handlers(message, instance) do
    {active, suspended} =
      instance
      |> Instance.handlers()
      |> Enum.split_with(&(not &1.suspended))

    """
    #{message}

    #{format_handlers(active, suspended)}
    """
  end

  defp format_handlers([], []) do
    "No active handlers."
  end

  defp format_handlers([], suspended) do
    """
    No active handlers. The following handlers have been processed:

    #{Instance.format_handlers(suspended)}
    """
  end

  defp format_handlers(active, _suspended) do
    """
    Active handlers:

    #{Instance.format_handlers(active)}
    """
  end

  defp handle_error(connection, state, {exception, stacktrace}) do
    Instance.report_error(state.instance, {exception, stacktrace})

    error_message = Exception.format(:error, exception, stacktrace)
    :ssh_connection.send(connection, state.channel_id, error_message)
  end
end
