defmodule TestServer.SSH.Channel do
  @moduledoc false

  @behaviour :ssh_server_channel

  alias TestServer.SSH.Instance

  defstruct [:instance, :channel_id, :connection, type: nil, handler_state: %{}]

  @impl true
  def init(instance: instance) do
    {:ok, %__MODULE__{instance: instance}}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, connection}, state) do
    {:ok, %{state | channel_id: channel_id, connection: connection}}
  end

  def handle_msg(_msg, state) do
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, conn, {:exec, ch_id, want_reply, command}}, state) do
    command = to_string(command)
    :ssh_connection.reply_request(conn, want_reply, :success, ch_id)

    case GenServer.call(state.instance, {:dispatch, {:exec, command, state.handler_state}}) do
      {:ok, {:reply, {exit_code, stdout, stderr}, new_handler_state}} ->
        unless IO.iodata_length(stdout) == 0,
          do: :ssh_connection.send(conn, ch_id, stdout)

        unless IO.iodata_length(stderr) == 0,
          do: :ssh_connection.send(conn, ch_id, 1, stderr)

        :ssh_connection.exit_status(conn, ch_id, exit_code)
        :ssh_connection.send_eof(conn, ch_id)
        :ssh_connection.close(conn, ch_id)
        {:stop, ch_id, %{state | handler_state: new_handler_state}}

      {:ok, {:ok, new_handler_state}} ->
        :ssh_connection.exit_status(conn, ch_id, 0)
        :ssh_connection.send_eof(conn, ch_id)
        :ssh_connection.close(conn, ch_id)
        {:stop, ch_id, %{state | handler_state: new_handler_state}}

      {:error, :not_found} ->
        message =
          "#{TestServer.format_instance(TestServer.SSH, state.instance)} received an unexpected SSH exec request: #{inspect(command)}"

        report_error_and_close_exec(conn, ch_id, state, RuntimeError.exception(message), [])

      {:error, {exception, stacktrace}} ->
        report_error_and_close_exec(conn, ch_id, state, exception, stacktrace)
    end
  end

  def handle_ssh_msg({:ssh_cm, conn, {:shell, ch_id, want_reply}}, state) do
    :ssh_connection.reply_request(conn, want_reply, :success, ch_id)
    {:ok, %{state | type: :shell, channel_id: ch_id, connection: conn}}
  end

  def handle_ssh_msg({:ssh_cm, conn, {:data, ch_id, 0, data}}, %{type: :shell} = state) do
    :ssh_connection.adjust_window(conn, ch_id, byte_size(data))

    case GenServer.call(state.instance, {:dispatch, {:shell, data, state.handler_state}}) do
      {:ok, {:reply, output, new_handler_state}} ->
        :ssh_connection.send(conn, ch_id, output)
        {:ok, %{state | handler_state: new_handler_state}}

      {:ok, {:ok, new_handler_state}} ->
        {:ok, %{state | handler_state: new_handler_state}}

      {:error, :not_found} ->
        message =
          "#{TestServer.format_instance(TestServer.SSH, state.instance)} received unexpected SSH shell data: #{inspect(data)}"

        Instance.report_error(state.instance, {RuntimeError.exception(message), []})
        {:ok, state}

      {:error, {exception, stacktrace}} ->
        Instance.report_error(state.instance, {exception, stacktrace})
        {:ok, state}
    end
  end

  def handle_ssh_msg({:ssh_cm, conn, {:pty, ch_id, want_reply, _pty_info}}, state) do
    :ssh_connection.reply_request(conn, want_reply, :success, ch_id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, conn, {:env, ch_id, want_reply, _name, _value}}, state) do
    :ssh_connection.reply_request(conn, want_reply, :success, ch_id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:eof, _ch_id}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:closed, ch_id}}, state) do
    {:stop, ch_id, state}
  end

  def handle_ssh_msg(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp report_error_and_close_exec(conn, ch_id, state, exception, stacktrace) do
    Instance.report_error(state.instance, {exception, stacktrace})
    :ssh_connection.exit_status(conn, ch_id, 1)
    :ssh_connection.send_eof(conn, ch_id)
    :ssh_connection.close(conn, ch_id)
    {:stop, ch_id, state}
  end
end
