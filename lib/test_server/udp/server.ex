defmodule TestServer.UDP.Server do
  @moduledoc false

  alias TestServer.UDP.Instance

  @doc false
  @spec start(TestServer.instance(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def start(instance, options) do
    transport = validate_transport!(Keyword.get(options, :transport, :udp))
    port = TestServer.validate_port!(options)

    options =
      options
      |> put_tls_options(transport)
      |> Keyword.put(:transport, transport)

    listen_options = listen_options(options, transport)

    with {:ok, socket, port} <- transport_listen(transport, port, listen_options) do
      receiver = start_receiver(instance, socket)
      {_transport, raw_socket} = socket

      {:ok,
       options
       |> Keyword.put(:port, port)
       |> Keyword.put(:listener, raw_socket)
       |> Keyword.put(:receiver, receiver)}
    end
  end

  defp validate_transport!(transport) when transport in [:udp, :dtls], do: transport

  defp validate_transport!(transport) do
    raise ArgumentError, "expected :udp or :dtls transport, got: #{inspect(transport)}"
  end

  defp put_tls_options(options, :dtls) do
    options
    |> TestServer.put_tls_options({:ec, :secp256r1})
    |> Keyword.update!(:tls, &Keyword.put_new(&1, :log_level, :warning))
  end

  defp put_tls_options(options, :udp), do: options

  defp listen_options(options, transport) do
    tls_options = Keyword.get(options, :tls, [])

    [mode: :binary]
    |> Keyword.merge(Keyword.get(options, :listen, []))
    |> Keyword.merge((transport == :dtls && tls_options) || [])
    |> Keyword.put(:active, false)
    |> then(fn listen_options ->
      case Keyword.get(options, :ipfamily, :inet) do
        :inet -> listen_options
        ipfamily -> [ipfamily | listen_options]
      end
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
        {:ok, {transport, socket}, transport_port({transport, socket})}

      {:error, reason} ->
        exception =
          RuntimeError.exception(
            "Could not listen to port #{inspect(port)}, because: #{inspect(reason)}"
          )

        {:error, exception}
    end
  end

  defp transport_port({transport, raw_socket}) do
    {:ok, {_address, port}} =
      case transport do
        :udp -> :inet.sockname(raw_socket)
        :dtls -> :ssl.sockname(raw_socket)
      end

    port
  end

  defp start_receiver(instance, {:udp, raw_socket} = listener) do
    {:ok, receiver} =
      Task.start_link(fn ->
        receive do
          :start -> :ok
        end

        receive_loop(instance, listener, %{})
      end)

    :ok = :gen_udp.controlling_process(raw_socket, receiver)
    send(receiver, :start)

    receiver
  end

  defp start_receiver(instance, {:dtls, _raw_socket} = listener) do
    {:ok, receiver} = Task.start_link(fn -> accept_loop(instance, listener) end)

    receiver
  end

  defp receive_loop(instance, {:udp, raw_socket} = listener, peers) do
    case :gen_udp.recv(raw_socket, 0) do
      {:ok, {address, port, data}} ->
        socket = {:udp, raw_socket, address, port}
        peer = Map.get_lazy(peers, {address, port}, fn -> start_peer(instance, socket) end)

        case Process.alive?(peer) do
          true ->
            send(peer, {:udp, raw_socket, data})
            receive_loop(instance, listener, Map.put(peers, {address, port}, peer))

          false ->
            message = "Could not handle UDP data, because: Peer process no longer accepts data."

            send_error(socket, RuntimeError.exception(message), instance)
        end

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        raise "Could not receive UDP data, because: #{inspect(reason)}"
    end
  end

  defp accept_loop(instance, {:dtls, raw_socket} = listener) do
    case :ssl.transport_accept(raw_socket) do
      {:ok, raw_socket} ->
        start_peer(instance, {:dtls, raw_socket})
        accept_loop(instance, listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        raise "Could not accept UDP peer, because: #{inspect(reason)}"
    end
  end

  defp start_peer(instance, {:udp, _listener, _address, _port} = socket) do
    {:ok, peer} =
      Task.start_link(fn ->
        Process.link(instance)

        assign_peer(instance, socket)
      end)

    peer
  end

  defp start_peer(instance, {:dtls, raw_socket}) do
    {:ok, peer} =
      Task.start_link(fn ->
        Process.link(instance)

        receive do
          :start -> :ok
        end

        {:dtls, raw_socket} =
          case dtls_handshake(raw_socket) do
            {:ok, raw_socket} -> assign_peer(instance, {:dtls, raw_socket})
            {:error, _reason} -> {:dtls, raw_socket}
          end

        :ssl.close(raw_socket)
      end)

    :ok = :ssl.controlling_process(raw_socket, peer)
    send(peer, :start)

    peer
  end

  defp dtls_handshake(raw_socket) do
    case :ssl.handshake(raw_socket) do
      {:ok, raw_socket} ->
        {:ok, raw_socket}

      {:ok, raw_socket, _extensions} ->
        :ssl.handshake_continue(raw_socket, [])

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
          "#{TestServer.format_instance(TestServer.UDP, instance)} received an unexpected UDP peer"
          |> append_formatted_peers(instance)

        send_error(socket, RuntimeError.exception(message), instance)

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
        message = "UDP receive failed, because: #{inspect(reason)}"

        {:error, RuntimeError.exception(message)}

      {:send, {options, stacktrace}} ->
        handle_send(instance, socket, {options, stacktrace}, state)
    end
    |> case do
      {:ok, socket, state} ->
        socket_loop(instance, socket, state)

      {:error, reason} ->
        send_error(socket, reason, instance)
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
          "#{TestServer.format_instance(TestServer.UDP, instance)} received unexpected UDP data"
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
        exception = RuntimeError.exception("UDP reply failed, because: #{inspect(reason)}")

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

  defp send_error(socket, {exception, stacktrace}, instance) do
    TestServer.report_error(Instance.options(instance), {exception, stacktrace})

    message = Exception.format(:error, exception, stacktrace)

    transport_send(socket, message)
  end

  defp send_error(socket, reason, instance), do: send_error(socket, {reason, []}, instance)

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
