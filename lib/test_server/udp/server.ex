defmodule TestServer.UDP.Server do
  @moduledoc false

  alias TestServer.UDP.Instance

  @doc false
  @spec start(TestServer.instance(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def start(instance, options) do
    transport = validate_transport!(options)
    port = TestServer.validate_port!(options)
    {ipfamily, ip} = TestServer.validate_ip!(options)

    options =
      options
      |> Keyword.put(:ipfamily, ipfamily)
      |> Keyword.put(:ip, ip)
      |> put_tls_options(transport)
      |> Keyword.put(:transport, transport)

    listen_options = listen_options(options, transport)

    with {:ok, socket, {ip, port}} <- transport_listen(transport, port, listen_options) do
      {:ok, receiver_pid} = start_receiver(instance, socket)
      :ok = TestServer.supervise_server(receiver_pid, fn _ -> transport_close(socket) end)
      {_transport, listener_socket} = socket

      {:ok,
       options
       |> Keyword.put(:ip, ip)
       |> Keyword.put(:port, port)
       |> Keyword.put(:listener, listener_socket)
       |> Keyword.put(:receiver, receiver_pid)}
    end
  end

  defp validate_transport!(options) do
    transport = Keyword.get(options, :transport, :udp)

    case transport in [:udp, :dtls] do
      true ->
        transport

      false ->
        raise ArgumentError, "expected :transport to be :udp or :dtls, got: #{inspect(transport)}"
    end
  end

  defp put_tls_options(options, :dtls) do
    options
    |> TestServer.put_tls_options(key_type: {:ec, :secp256r1})
    |> Keyword.update!(:tls, &Keyword.put_new(&1, :log_level, :warning))
  end

  defp put_tls_options(options, :udp), do: options

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
    |> Keyword.merge((transport == :dtls && tls_options) || [])
    |> Keyword.put(:active, false)
    |> then(fn listen_options ->
      listen_atoms ++ listen_options
    end)
  end

  defp transport_listen(transport, port, options) do
    transport
    |> case do
      :udp -> :gen_udp.open(port, options)
      :dtls -> :ssl.listen(port, Keyword.put(options, :protocol, :dtls))
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
        :udp -> :inet.sockname(raw_socket)
        :dtls -> :ssl.sockname(raw_socket)
      end

    address
  end

  defp start_receiver(instance, {:udp, raw_socket} = listener) do
    {:ok, receiver_pid} =
      Task.start(fn ->
        receive do
          :start -> :ok
        end

        receive_loop(instance, listener, %{})
      end)

    :ok = :gen_udp.controlling_process(raw_socket, receiver_pid)
    send(receiver_pid, :start)

    {:ok, receiver_pid}
  end

  defp start_receiver(instance, {:dtls, _raw_socket} = listener) do
    Task.start(fn -> accept_loop(instance, listener) end)
  end

  defp receive_loop(instance, {:udp, raw_socket} = listener, peers) do
    case :gen_udp.recv(raw_socket, 0) do
      {:ok, {address, port, data}} ->
        socket = {:udp, raw_socket, address, port}
        peer = Map.get_lazy(peers, {address, port}, fn -> start_peer(instance, socket) end)

        peers =
          case Process.alive?(peer) do
            true ->
              send(peer, {:udp, raw_socket, data})

              Map.put(peers, {address, port}, peer)

            false ->
              message = "could not handle UDP data: peer process no longer accepts data"

              send_error(socket, instance, RuntimeError.exception(message))

              peers
          end

        receive_loop(instance, listener, peers)

      {:error, :closed} ->
        exit(:shutdown)

      {:error, reason} ->
        raise "could not receive UDP data: #{inspect(reason)}"
    end
  end

  defp accept_loop(instance, {:dtls, raw_socket} = listener) do
    case :ssl.transport_accept(raw_socket) do
      {:ok, raw_socket} ->
        start_peer(instance, {:dtls, raw_socket})
        accept_loop(instance, listener)

      {:error, :closed} ->
        exit(:shutdown)

      {:error, reason} ->
        raise "could not accept UDP peer: #{inspect(reason)}"
    end
  end

  defp start_peer(instance, {:udp, _listener, _address, _port} = socket) do
    {:ok, owner_pid} =
      Task.start_link(fn ->
        assign_peer(instance, socket)
      end)

    owner_pid
  end

  defp start_peer(instance, {:dtls, raw_socket}) do
    {:ok, owner_pid} =
      Task.start_link(fn ->
        receive do
          :start -> :ok
        end

        {:dtls, raw_socket} =
          case dtls_handshake(raw_socket) do
            {:ok, raw_socket} -> assign_peer(instance, {:dtls, raw_socket})
            {:error, _reason} -> {:dtls, raw_socket}
          end

        transport_close({:dtls, raw_socket})
      end)

    :ok = :ssl.controlling_process(raw_socket, owner_pid)
    send(owner_pid, :start)

    owner_pid
  end

  @handshake_timeout 5_000

  defp dtls_handshake(raw_socket) do
    case :ssl.handshake(raw_socket, @handshake_timeout) do
      {:ok, raw_socket} ->
        {:ok, raw_socket}

      {:ok, raw_socket, _extensions} ->
        :ssl.handshake_continue(raw_socket, [], @handshake_timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assign_peer(instance, socket) do
    case Instance.dispatch(instance, {:peer, self(), socket}) do
      {:ok, _peer, state} ->
        socket_loop(instance, socket, state)

      {:error, :not_found} ->
        message =
          "#{TestServer.format_instance(instance)} received an unexpected UDP peer"
          |> append_formatted_peers(instance)

        send_error(socket, instance, RuntimeError.exception(message))

        socket
    end
  end

  defp socket_loop(instance, {:udp, _, _, _} = socket, state) do
    receive_socket_message(instance, socket, state)
  end

  defp socket_loop(instance, {:dtls, raw_socket} = socket, state) do
    case :ssl.setopts(raw_socket, active: :once) do
      :ok -> receive_socket_message(instance, socket, state)
      # This normally happens on client disconnects so no need to surface
      {:error, _reason} -> socket
    end
  end

  defp receive_socket_message(instance, socket, state) do
    raw_socket = elem(socket, 1)

    receive do
      {:udp, ^raw_socket, data} ->
        handle_data(instance, socket, data, state)

      {:ssl, ^raw_socket, data} ->
        handle_data(instance, socket, data, state)

      {:ssl_closed, ^raw_socket} ->
        {:ok, socket, state}

      {:ssl_error, ^raw_socket, reason} ->
        message = "could not receive UDP data: #{inspect(reason)}"

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
      {:reply, data, state} ->
        send_data(data, socket, state)

      {:ok, state} ->
        {:ok, socket, state}

      {:error, :not_found} ->
        message =
          "#{TestServer.format_instance(instance)} received unexpected UDP data"
          |> append_formatted_data(data)
          |> append_formatted_handlers(instance)

        {:error, RuntimeError.exception(message)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_data(data, socket, state) do
    case transport_send(socket, data) do
      :ok ->
        {:ok, socket, state}

      {:error, reason} ->
        exception = RuntimeError.exception("could not send UDP reply: #{inspect(reason)}")

        {:error, exception}
    end
  end

  defp transport_send({:udp, raw_socket, address, port}, data) do
    :gen_udp.send(raw_socket, address, port, data)
  end

  defp transport_send({:dtls, raw_socket}, data), do: :ssl.send(raw_socket, data)

  defp handle_send(instance, socket, {options, stacktrace}, state) do
    case Instance.dispatch(instance, {:send, options, state, stacktrace}) do
      {:reply, data, state} -> send_data(data, socket, state)
      {:ok, state} -> {:ok, socket, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transport_close({:udp, raw_socket}) do
    :gen_udp.close(raw_socket)
  end

  defp transport_close({:dtls, raw_socket}) do
    :ssl.close(raw_socket)
  end

  defp send_error(socket, instance, {exception, stacktrace}) do
    options = Instance.options(instance)
    :ok = TestServer.report_error(instance, {exception, stacktrace}, options)
    message = Exception.format(:error, exception, stacktrace)

    transport_send(socket, message)
  end

  defp send_error(socket, instance, reason), do: send_error(socket, instance, {reason, []})

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

  defp append_formatted_peers(message, instance) do
    """
    #{message}

    #{format_peers(Instance.peers(instance))}
    """
  end

  defp format_peers([]), do: "No peers registered."

  defp format_peers(peers) do
    """
    The following peers were registered:

    #{Instance.format_peers(peers)}
    """
  end
end
