defmodule TestServer.TCP.Server do
  @moduledoc false

  alias TestServer.TCP.Instance

  @doc false
  @spec start(TestServer.instance(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def start(instance, options) do
    with {:ok, port} <- TestServer.open_port(options),
         listen_options = listen_options(options),
         {:ok, listener} <- :gen_tcp.listen(port, listen_options) do
      {:ok, _acceptor} = Task.start_link(fn -> accept_loop(instance, listener) end)

      options =
        options
        |> Keyword.put(:port, port)
        |> Keyword.put(:listener, listener)

      {:ok, options}
    end
  end

  defp listen_options(options) do
    [mode: :binary]
    |> Keyword.merge(Keyword.get(options, :listen, []))
    |> Keyword.put(:active, false)
    |> then(fn listen_options ->
      case Keyword.get(options, :ipfamily, :inet) do
        :inet -> listen_options
        ipfamily -> [ipfamily | listen_options]
      end
    end)
  end

  defp accept_loop(instance, listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handle_accepted_socket(instance, socket, listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        raise "Could not accept TCP connection, because: #{inspect(reason)}"
    end
  end

  defp handle_accepted_socket(instance, socket, listener) do
    {:ok, owner} = Task.start_link(fn -> run_socket(instance, socket) end)
    :ok = :gen_tcp.controlling_process(socket, owner)

    case Instance.dispatch(instance, {:connection, owner, socket}) do
      {:ok, _connection} ->
        send(owner, :start)

      {:error, :not_found} ->
        message =
          "#{TestServer.format_instance(TestServer.TCP, instance)} received an unexpected TCP connection attempt"
          |> append_formatted_connections(instance)

        send_error(socket, {RuntimeError.exception(message), []}, instance)
        :gen_tcp.close(socket)
        send(owner, :stop)
    end

    accept_loop(instance, listener)
  end

  defp run_socket(instance, socket) do
    receive do
      :start -> socket_loop(instance, socket)
      :stop -> :ok
    end
  after
    :gen_tcp.close(socket)
  end

  defp socket_loop(instance, socket) do
    case :inet.setopts(socket, active: :once) do
      :ok ->
        receive_socket_message(instance, socket)

      {:error, _reason} ->
        :ok
    end
  end

  defp receive_socket_message(instance, socket) do
    receive do
      {:tcp, ^socket, data} ->
        instance
        |> Instance.dispatch({:handle, self(), data})
        |> handle_result(instance, socket, data)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, reason} ->
        exception = RuntimeError.exception("TCP receive failed, because: #{inspect(reason)}")
        send_error(socket, {exception, []}, instance)
        :gen_tcp.close(socket)

      {:write, data} ->
        handle_result({:reply, data}, instance, socket, nil)
    end
  end

  defp handle_result({:reply, data}, instance, socket, _data) do
    case :gen_tcp.send(socket, data) do
      :ok ->
        socket_loop(instance, socket)

      {:error, reason} ->
        exception = RuntimeError.exception("TCP reply failed, because: #{inspect(reason)}")
        send_error(socket, {exception, []}, instance)
        :gen_tcp.close(socket)
    end
  end

  defp handle_result(:ok, instance, socket, _data) do
    socket_loop(instance, socket)
  end

  defp handle_result({:error, :not_found}, instance, socket, data) do
    message =
      "#{TestServer.format_instance(TestServer.TCP, instance)} received unexpected TCP data"
      |> append_formatted_data(data)
      |> append_formatted_handlers(instance)

    send_error(socket, {RuntimeError.exception(message), []}, instance)
    :gen_tcp.close(socket)
  end

  defp handle_result({:error, {exception, stacktrace}}, instance, socket, _data) do
    send_error(socket, {exception, stacktrace}, instance)
    :gen_tcp.close(socket)
  end

  defp send_error(socket, {exception, stacktrace}, instance) do
    TestServer.report_error(Instance.options(instance), {exception, stacktrace})

    message = Exception.format(:error, exception, stacktrace)

    :gen_tcp.send(socket, message)
  end

  defp append_formatted_connections(message, instance) do
    connections = Enum.split_with(Instance.connections(instance), &is_nil(&1.owner))

    """
    #{message}

    #{format_connections(connections)}
    """
  end

  defp append_formatted_data(message, data) do
    """
    #{message}:

    #{inspect(data)}
    """
  end

  defp append_formatted_handlers(message, instance) do
    handlers = Enum.split_with(Instance.handlers(instance), &(not &1.suspended))

    """
    #{message}

    #{format_handlers(handlers)}
    """
  end

  defp format_connections({[], used_connections}) do
    message = "No available connections."

    case used_connections do
      [] ->
        message

      used_connections ->
        """
        #{message} The following connections have been used:

        #{Instance.format_connections(used_connections)}
        """
    end
  end

  defp format_connections({available_connections, _used_connections}) do
    """
    Available connections:

    #{Instance.format_connections(available_connections)}
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

  @doc false
  @spec stop(keyword(), [map()]) :: :ok
  def stop(options, connections) do
    options
    |> Keyword.fetch!(:listener)
    |> :gen_tcp.close()

    Enum.each(connections, fn
      %{socket: nil} -> :ok
      %{socket: socket} -> :gen_tcp.close(socket)
    end)
  end
end
