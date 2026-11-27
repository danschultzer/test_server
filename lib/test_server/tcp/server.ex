defmodule TestServer.TCP.Server do
  @moduledoc false

  alias TestServer.TCP.Instance

  @doc false
  @spec start(TestServer.instance(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def start(instance, options) do
    {default_transport, transports} = validate_transport!(options)
    port = TestServer.validate_port!(options)
    {ipfamily, ip} = TestServer.validate_ip!(options)

    options =
      options
      |> Keyword.put(:ipfamily, ipfamily)
      |> Keyword.put(:ip, ip)
      |> put_tls_options(transports)
      |> Keyword.put(:transport, transports)

    listen_options = listen_options(options, default_transport)

    case transport_listen(default_transport, port, listen_options) do
      {:ok, socket, {ip, port}} ->
        {:ok, acceptor_pid} = Task.start(fn -> accept_loop(instance, socket) end)
        :ok = TestServer.supervise_server(acceptor_pid, fn _ -> transport_close(socket) end)
        {_transport, listener_socket} = socket

        options =
          options
          |> Keyword.put(:ip, ip)
          |> Keyword.put(:port, port)
          |> Keyword.put(:listener, listener_socket)
          |> Keyword.put(:acceptor, acceptor_pid)

        {:ok, options}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_transport!(options) do
    transport = Keyword.get(options, :transport, :tcp)
    transports = List.wrap(transport)
    not_empty? = transports != []
    valid? = transports -- [:tcp, :tls] == []

    case not_empty? and valid? do
      true ->
        default_transport = (:tcp in transports && :tcp) || List.first(transports)

        {default_transport, transports}

      false ->
        raise ArgumentError,
              "expected :transport to be :tcp, :tls, or a non-empty list of those values, got: #{inspect(transport)}"
    end
  end

  defp put_tls_options(options, transports) do
    case :tls in transports do
      true ->
        options
        |> TestServer.put_tls_options()
        |> Keyword.update!(:tls, &Keyword.put_new(&1, :log_level, :warning))

      false ->
        options
    end
  end

  defp listen_options(options, transport) do
    tls_options = Keyword.get(options, :tls, [])

    {listen_atoms, listen_options} =
      options
      |> Keyword.get(:listen, [])
      |> TestServer.split_atom_options_with_ipfamily(options)

    options
    |> Keyword.take([:ip])
    |> Keyword.put(:mode, :binary)
    |> Keyword.merge(listen_options)
    |> Keyword.merge((transport == :tls && tls_options) || [])
    |> Keyword.put(:active, false)
    |> then(fn listen_options ->
      listen_atoms ++ listen_options
    end)
  end

  defp transport_listen(transport, port, options) do
    transport
    |> case do
      :tcp -> :gen_tcp.listen(port, options)
      :tls -> :ssl.listen(port, options)
    end
    |> case do
      {:ok, socket} ->
        {:ok, {transport, socket}, transport_address({transport, socket})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transport_address({transport, raw_socket}) do
    {:ok, address} =
      case transport do
        :tcp -> :inet.sockname(raw_socket)
        :tls -> :ssl.sockname(raw_socket)
      end

    address
  end

  defp accept_loop(instance, listener) do
    case transport_accept(listener, instance) do
      {:ok, socket} ->
        start_socket(instance, socket)
        accept_loop(instance, listener)

      {:error, :closed} ->
        exit({:shutdown, :closed})

      {:error, reason} ->
        raise "could not accept TCP connection: #{inspect(reason)}"
    end
  end

  defp transport_accept({transport, raw_socket}, instance) do
    transport
    |> case do
      :tcp -> :gen_tcp.accept(raw_socket)
      :tls -> :ssl.transport_accept(raw_socket)
    end
    |> case do
      {:ok, raw_socket} ->
        {:ok, {transport, raw_socket}}

      {:error, reason} ->
        {TestServer.TCP, instance_pid} = instance

        case Process.alive?(instance_pid) do
          true -> {:error, reason}
          false -> {:error, :closed}
        end
    end
  catch
    :exit, reason ->
      {TestServer.TCP, instance_pid} = instance

      case Process.alive?(instance_pid) do
        true -> :erlang.raise(:exit, reason, __STACKTRACE__)
        false -> {:error, :closed}
      end
  end

  defp start_socket(instance, socket) do
    {:ok, owner_pid} =
      Task.start_link(fn ->
        receive do
          :start -> :ok
        end

        socket =
          case transport_handshake(socket) do
            {:ok, socket} -> assign_connection(instance, socket)
            # This normally happens on TLS connect errors so no need to surface
            {:error, _reason} -> socket
          end

        transport_close(socket)
      end)

    :ok = transport_controlling_process(socket, owner_pid)

    send(owner_pid, :start)

    :ok
  end

  @handshake_timeout 5_000

  defp transport_handshake({transport, raw_socket}, options \\ []) do
    transport
    |> case do
      :tcp -> {:ok, raw_socket}
      :tls -> :ssl.handshake(raw_socket, options, @handshake_timeout)
    end
    |> case do
      {:ok, raw_socket} ->
        {:ok, {transport, raw_socket}}

      {:ok, raw_socket, _extensions} ->
        transport_handshake_continue(raw_socket, transport)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transport_handshake_continue(raw_socket, :tls) do
    case :ssl.handshake_continue(raw_socket, [], @handshake_timeout) do
      {:ok, raw_socket} -> {:ok, {:tls, raw_socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assign_connection(instance, socket) do
    case Instance.dispatch(instance, {:connection, self(), socket}) do
      {:ok, _connection, state} ->
        socket_loop(instance, socket, state)

      {:error, :not_found} ->
        message =
          "#{TestServer.format_instance(instance)} received an unexpected TCP connection attempt"
          |> append_formatted_connections(instance)

        send_error(socket, instance, RuntimeError.exception(message))

        socket
    end
  end

  defp socket_loop(instance, socket, state) do
    case transport_setopts(socket, active: :once) do
      :ok -> receive_socket_message(instance, socket, state)
      # This normally happens on client disconnects so no need to surface
      {:error, _reason} -> socket
    end
  end

  defp transport_setopts({transport, raw_socket}, opts) do
    case transport do
      :tcp -> :inet.setopts(raw_socket, opts)
      :tls -> :ssl.setopts(raw_socket, opts)
    end
  end

  defp receive_socket_message(instance, {_transport, raw_socket} = socket, state) do
    receive do
      {:tcp, ^raw_socket, data} ->
        handle_data(instance, socket, data, state)

      {:ssl, ^raw_socket, data} ->
        handle_data(instance, socket, data, state)

      {:tcp_closed, ^raw_socket} ->
        {:ok, socket, state}

      {:ssl_closed, ^raw_socket} ->
        {:ok, socket, state}

      {:tcp_error, ^raw_socket, reason} ->
        message = "could not receive TCP data: #{inspect(reason)}"

        {:error, RuntimeError.exception(message)}

      {:ssl_error, ^raw_socket, reason} ->
        message = "could not receive TCP data: #{inspect(reason)}"

        {:error, RuntimeError.exception(message)}

      {:send, {options, stacktrace}} ->
        handle_send(instance, socket, {options, stacktrace}, state)
    end
    |> case do
      {:ok, socket, state} ->
        socket_loop(instance, socket, state)

      {:error, reason} ->
        send_error(socket, instance, reason)
        socket
    end
  end

  defp handle_data(instance, socket, data, state) do
    case Instance.dispatch(instance, {:handle, self(), data, state}) do
      {:reply, {data, options}, state} ->
        handle_reply(instance, socket, {data, options}, state)

      {:ok, state} ->
        {:ok, socket, state}

      {:error, :not_found} ->
        message =
          "#{TestServer.format_instance(instance)} received unexpected TCP data"
          |> append_formatted_data(data)
          |> append_formatted_handlers(instance)

        {:error, RuntimeError.exception(message)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_reply(instance, socket, {data, reply_options}, state) do
    {current_transport, _raw_socket} = socket

    case validate_transport_upgrade(instance, current_transport, reply_options) do
      {:ok, new_transport} ->
        data
        |> send_data(socket, state)
        |> maybe_transport_upgrade(instance, new_transport)

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_transport_upgrade(instance, current_transport, reply_options) do
    new_transport = Keyword.get(reply_options, :upgrade)
    transports = instance |> Instance.options() |> Keyword.fetch!(:transport)
    tls? = :tls in transports

    case {tls?, current_transport, new_transport} do
      {_tls?, _current_transport, nil} ->
        {:ok, current_transport}

      {true, :tcp, :tls} ->
        {:ok, :tls}

      {false, :tcp, :tls} ->
        reason =
          RuntimeError.exception(
            "cannot upgrade TCP transport to TLS without the [transport: [:tcp, :tls]] option"
          )

        {:error, reason}

      {_tls?, current_transport, new_transport} ->
        reason =
          RuntimeError.exception(
            "can only upgrade TCP transport from TCP to TLS, got: #{inspect(current_transport)} to #{inspect(new_transport)}"
          )

        {:error, reason}
    end
  end

  defp send_data(data, socket, state) do
    case transport_send(socket, data) do
      :ok ->
        {:ok, socket, state}

      {:error, reason} ->
        exception = RuntimeError.exception("could not send TCP reply: #{inspect(reason)}")

        {:error, exception}
    end
  end

  defp transport_send({transport, raw_socket}, data) do
    case transport do
      :tcp -> :gen_tcp.send(raw_socket, data)
      :tls -> :ssl.send(raw_socket, data)
    end
  end

  defp maybe_transport_upgrade({:error, reason}, _instance, _new_transport) do
    {:error, reason}
  end

  defp maybe_transport_upgrade({:ok, {transport, _socket} = socket, state}, _instance, transport) do
    {:ok, socket, state}
  end

  defp maybe_transport_upgrade({:ok, {:tcp, _} = socket, state}, instance, :tls) do
    options = Instance.options(instance)

    case transport_upgrade(socket, options) do
      {:ok, tls_socket} ->
        {:ok, _connection, _state} =
          Instance.dispatch(instance, {:connection, self(), tls_socket})

        {:ok, tls_socket, state}

      {:error, reason} ->
        {:error, RuntimeError.exception("could not upgrade TCP transport: #{inspect(reason)}")}
    end
  end

  defp transport_upgrade({:tcp, raw_socket}, options) do
    listen_options = listen_options(options, :tls)

    case transport_setopts({:tcp, raw_socket}, active: false) do
      :ok -> transport_handshake({:tls, raw_socket}, listen_options)
      {:error, error} -> {:error, error}
    end
  end

  defp handle_send(instance, socket, {options, stacktrace}, state) do
    case Instance.dispatch(instance, {:send, options, state, stacktrace}) do
      {:reply, data, state} -> send_data(data, socket, state)
      {:ok, state} -> {:ok, socket, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_error(socket, instance, {exception, stacktrace}) do
    options = Instance.options(instance)
    :ok = TestServer.report_error(instance, {exception, stacktrace}, options)
    message = Exception.format(:error, exception, stacktrace)

    transport_send(socket, message)
  end

  defp send_error(socket, instance, reason), do: send_error(socket, instance, {reason, []})

  defp transport_close({transport, raw_socket}) do
    case transport do
      :tcp -> :gen_tcp.close(raw_socket)
      :tls -> :ssl.close(raw_socket)
    end
  end

  defp transport_controlling_process({transport, raw_socket}, owner_pid) do
    case transport do
      :tcp -> :gen_tcp.controlling_process(raw_socket, owner_pid)
      :tls -> :ssl.controlling_process(raw_socket, owner_pid)
    end
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

  defp append_formatted_connections(message, instance) do
    """
    #{message}

    #{format_connections(Instance.connections(instance))}
    """
  end

  defp format_connections([]), do: "No connections registered."

  defp format_connections(connections) do
    """
    The following connections were registered:

    #{Instance.format_connections(connections)}
    """
  end
end
