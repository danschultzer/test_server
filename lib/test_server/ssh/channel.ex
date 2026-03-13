defmodule TestServer.SSH.Channel do
  @moduledoc false

  @behaviour :ssh_server_channel

  alias TestServer.SSH.Instance

  defstruct [:instance, :channel_id, :connection, :type, :channel_ref]

  @impl true
  def init(instance: instance) do
    {:ok, %__MODULE__{instance: instance}}
  end

  @impl true
  # Exec request — one-shot command execution
  def handle_ssh_msg(
        {:ssh_cm, connection, {:exec, channel_id, want_reply, command}},
        state
      ) do
    :ssh_connection.reply_request(connection, want_reply, :success, channel_id)

    {opts, state} = dispatch(%{state | type: :exec}, {:exec, to_string(command)})

    if opts[:stderr] do
      :ssh_connection.send(connection, channel_id, 1, to_string(opts[:stderr]))
    end

    exit_code = Keyword.get(opts, :exit, 0)
    :ssh_connection.exit_status(connection, channel_id, exit_code)

    :ssh_connection.send_eof(connection, channel_id)
    :ssh_connection.close(connection, channel_id)

    {:stop, channel_id, state}
  end

  # Shell request — opens interactive shell mode
  def handle_ssh_msg(
        {:ssh_cm, connection, {:shell, channel_id, want_reply}},
        state
      ) do
    :ssh_connection.reply_request(connection, want_reply, :success, channel_id)
    {:ok, %{state | type: :shell}}
  end

  # Shell data — dispatch each data message
  def handle_ssh_msg(
        {:ssh_cm, connection, {:data, channel_id, 0, data}},
        %{type: :shell} = state
      ) do
    :ssh_connection.adjust_window(connection, channel_id, byte_size(data))

    {_opts, state} = dispatch(state, {:data, to_string(data)})

    {:ok, state}
  end

  # PTY request — accept silently
  def handle_ssh_msg({:ssh_cm, connection, {:pty, channel_id, want_reply, _pty}}, state) do
    :ssh_connection.reply_request(connection, want_reply, :success, channel_id)
    {:ok, state}
  end

  # Environment variable — accept silently
  def handle_ssh_msg({:ssh_cm, connection, {:env, channel_id, want_reply, _var, _val}}, state) do
    :ssh_connection.reply_request(connection, want_reply, :success, channel_id)
    {:ok, state}
  end

  # EOF — ignore
  def handle_ssh_msg({:ssh_cm, _connection, {:eof, _channel_id}}, state) do
    {:ok, state}
  end

  # Channel closed — stop
  def handle_ssh_msg({:ssh_cm, _connection, {:closed, channel_id}}, state) do
    {:stop, channel_id, state}
  end

  @impl true
  def handle_msg({:EXIT, _pid, _reason}, state) do
    {:stop, state.channel_id, state}
  end

  def handle_msg({:ssh_channel_up, channel_id, connection}, state) do
    case Instance.claim_channel(state.instance, connection) do
      {:ok, channel_ref} ->
        {:ok, %{state | channel_id: channel_id, connection: connection, channel_ref: channel_ref}}

      {:error, :no_channel} ->
        message =
          "#{TestServer.format_instance(TestServer.SSH, state.instance)} received an unexpected SSH channel"

        handle_error(
          %{state | channel_id: channel_id, connection: connection},
          {RuntimeError.exception(message), []}
        )

        {:stop, channel_id, state}
    end
  end

  def handle_msg(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  defp dispatch(state, {type, data}) do
    case Instance.dispatch(state.instance, {type, data}, state.channel_ref) do
      {:ok, {:reply, reply_data}} ->
        :ssh_connection.send(state.connection, state.channel_id, reply_data)
        {[], state}

      {:ok, {:reply, reply_data, opts}} ->
        :ssh_connection.send(state.connection, state.channel_id, reply_data)
        {opts, state}

      {:ok, :ok} ->
        {[], state}

      {:error, :not_found} ->
        handle_unexpected(state, state.type, data)
        {[exit: 1], state}

      {:error, {exception, stacktrace}} ->
        handle_error(state, {exception, stacktrace})
        {[exit: 1], state}
    end
  end

  defp handle_unexpected(state, type, input) do
    message =
      "#{TestServer.format_instance(TestServer.SSH, state.instance)} received an unexpected SSH message of type #{type}"
      |> append_formatted_ssh_msg(input)
      |> append_formatted_ssh_handlers(state.instance)

    handle_error(state, {RuntimeError.exception(message), []})
  end

  defp append_formatted_ssh_msg(message, input) do
    """
    #{message}:

    #{inspect(input)}
    """
  end

  defp append_formatted_ssh_handlers(message, instance) do
    handlers = Instance.handlers(instance)
    handler_info = Instance.format_handlers(handlers)

    """
    #{message}

    #{handler_info}
    """
  end

  defp handle_error(state, {exception, stacktrace}) do
    Instance.report_error(state.instance, {exception, stacktrace})

    error_message = Exception.format(:error, exception, stacktrace)
    :ssh_connection.send(state.connection, state.channel_id, error_message)
  end
end
