defmodule TestServer.TCP.Server do
  @moduledoc false

  import Kernel, except: [send: 2]

  alias TestServer.TCP.Instance

  @doc false
  @spec start(TestServer.instance(), keyword()) :: {:ok, keyword()}
  def start(instance, options) do
    port = fetch_port!(options)
    listen_options = listen_options(options)

    case :gen_tcp.listen(port, listen_options) do
      {:ok, listen_socket} ->
        {:ok, acceptor_pid} = Task.start_link(fn -> accept_loop(instance, listen_socket) end)
        {:ok, port} = :inet.port(listen_socket)

        options =
          options
          |> Keyword.put(:port, port)
          |> Keyword.put(:listen_options, listen_options)
          |> Keyword.put(:listen_socket, listen_socket)
          |> Keyword.put(:acceptor_pid, acceptor_pid)

        {:ok, options}

      {:error, reason} ->
        raise "Could not listen to port #{inspect(port)}, because: #{inspect(reason)}"
    end
  end

  defp fetch_port!(options) do
    port = Keyword.get(options, :port, 0)

    case is_integer(port) and port >= 0 and port <= 65_535 do
      true -> port
      false -> raise "Invalid port, got: #{inspect(port)}"
    end
  end

  defp listen_options(options) do
    options
    |> Keyword.get(:listen_options, [:binary, active: false, reuseaddr: true])
    |> List.wrap()
    |> Enum.reject(&match?({:active, _value}, &1))
    |> Kernel.++(active: false)
    |> put_ipfamily(Keyword.get(options, :ipfamily, :inet))
  end

  defp put_ipfamily(listen_options, :inet), do: listen_options
  defp put_ipfamily(listen_options, ipfamily), do: [ipfamily | listen_options]

  defp accept_loop(instance, listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        pid =
          spawn_link(fn ->
            receive do
              {:socket, socket} -> connection_loop(instance, socket)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        :ok = Instance.register_connection(instance, pid, socket)
        Kernel.send(pid, {:socket, socket})

        accept_loop(instance, listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        raise "Could not accept TCP connection, because: #{inspect(reason)}"
    end
  end

  defp connection_loop(instance, socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        instance
        |> Instance.dispatch({:handle, self(), data})
        |> respond(instance, socket, data)

      {:error, :closed} ->
        Instance.unregister_connection(instance, self())
        :ok

      {:error, reason} ->
        exception = RuntimeError.exception("TCP receive failed, because: #{inspect(reason)}")
        send_error(socket, {exception, []}, instance)
        :gen_tcp.close(socket)
        Instance.unregister_connection(instance, self())
    end
  end

  defp respond({:reply, data}, instance, socket, _data) do
    case :gen_tcp.send(socket, data) do
      :ok ->
        connection_loop(instance, socket)

      {:error, _reason} ->
        :gen_tcp.close(socket)
        Instance.unregister_connection(instance, self())
    end
  end

  defp respond(:ok, instance, socket, _data) do
    connection_loop(instance, socket)
  end

  defp respond({:error, :not_found}, instance, socket, data) do
    message =
      "#{TestServer.format_instance(TestServer.TCP, instance)} received unexpected TCP data"
      |> append_formatted_data(data)
      |> append_formatted_handlers(instance)

    send_error(socket, {RuntimeError.exception(message), []}, instance)
    :gen_tcp.close(socket)
    Instance.unregister_connection(instance, self())
  end

  defp respond({:error, {exception, stacktrace}}, instance, socket, _data) do
    send_error(socket, {exception, stacktrace}, instance)
    :gen_tcp.close(socket)
    Instance.unregister_connection(instance, self())
  end

  defp send_error(socket, {exception, stacktrace}, instance) do
    Instance.report_error(instance, {exception, stacktrace})

    message = Exception.format(:error, exception, stacktrace)
    :gen_tcp.send(socket, message)
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
  @spec send(port(), iodata()) :: :ok | {:error, term()}
  def send(socket, data) do
    :gen_tcp.send(socket, data)
  end

  @doc false
  @spec stop(keyword(), [map()]) :: :ok
  def stop(options, connections) do
    options
    |> Keyword.fetch!(:listen_socket)
    |> :gen_tcp.close()

    Enum.each(connections, fn
      %{socket: nil} -> :ok
      %{socket: socket} -> :gen_tcp.close(socket)
    end)
  end
end
