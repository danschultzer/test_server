if Code.ensure_loaded?(Bandit) do
  defmodule TestServer.HTTP.Server.Bandit do
    @moduledoc """
    HTTP server adapter using `Bandit`.

    By default only one acceptor process is started which is enough for
    testing. This adapter will be used by default if `Bandit` is loaded in the
    project.

    ## Usage

        TestServer.HTTP.start!(
          http_server: {TestServer.HTTP.Server.Bandit, bandit_options}
        )
    """
    @behaviour TestServer.HTTP.Server
    @behaviour WebSock

    alias TestServer.HTTP.WebSocket

    @impl TestServer.HTTP.Server
    def start(instance, port, scheme, options, bandit_options) do
      bandit_options = bandit_options(instance, port, scheme, options, bandit_options)
      trap_exit = Process.flag(:trap_exit, true)

      # Bandit crashes the instance if it fails to start so we must trap exits
      # to provide a proper error.
      result =
        try do
          Bandit.start_link(bandit_options)
        rescue
          exception -> {:error, exception}
        catch
          :exit, reason -> {:error, reason}
        after
          Process.flag(:trap_exit, trap_exit)
        end

      case result do
        {:ok, server_pid} ->
          true = Process.unlink(server_pid)
          {:ok, address} = ThousandIsland.listener_info(server_pid)

          {:ok, server_pid, address, bandit_options, &ThousandIsland.stop/1}

        {:error, error} ->
          {:error, error}
      end
    end

    defp bandit_options(instance, port, scheme, options, bandit_options) do
      bandit_options
      |> Keyword.put(
        :thousand_island_options,
        thousand_island_options(port, scheme, options, bandit_options)
      )
      |> Keyword.put(:plug, {TestServer.HTTP.Server.Bandit.Plug, {__MODULE__, [], instance}})
      |> Keyword.put(:scheme, scheme)
      |> Keyword.put_new(:startup_log, false)
    end

    defp thousand_island_options(port, scheme, options, bandit_options) do
      bandit_options
      |> Keyword.get(:thousand_island_options, [])
      # For tests it is not necessary to open the default 100 acceptor
      # processes
      |> Keyword.put_new(:num_acceptors, 1)
      |> Keyword.put(:port, port)
      |> Keyword.put(:transport_options, transport_options(scheme, options, bandit_options))
    end

    defp transport_options(scheme, options, bandit_options) do
      transport_options =
        bandit_options
        |> Keyword.get(:thousand_island_options, [])
        |> Keyword.get(:transport_options, [])

      {transport_atoms, transport_options} =
        TestServer.split_atom_options_with_ipfamily(transport_options, options)

      options
      |> Keyword.take([:ip])
      |> Keyword.merge(transport_options)
      |> then(fn transport_options ->
        case scheme do
          :http ->
            transport_options

          :https ->
            tls_options =
              options
              |> Keyword.get(:tls, [])
              |> Keyword.put_new(:log_level, :warning)

            Keyword.merge(transport_options, tls_options)
        end
      end)
      |> then(fn transport_options ->
        transport_atoms ++ transport_options
      end)
    end

    @impl TestServer.HTTP.Server
    def socket_pid(%{adapter: {TestServer.HTTP.Server.Bandit.Adapter, {_plug_pid, req}}}) do
      req.owner_pid
    end

    # WebSocket

    @impl WebSock
    def init({instance, websocket_ref, state}) do
      {:ok, {instance, websocket_ref, state}}
    end

    @impl WebSock
    def handle_in({data, opcode: opcode}, {instance, websocket_ref, state}),
      do: WebSocket.handle_frame({opcode, data}, {instance, websocket_ref, state})

    @impl WebSock
    def handle_info({:send, {options, stacktrace}}, {instance, websocket_ref, state}),
      do: WebSocket.handle_info({:send, {options, stacktrace}}, {instance, websocket_ref, state})

    def handle_info(_, {instance, websocket_ref, state}),
      do: {:ok, {instance, websocket_ref, state}}

    @impl WebSock
    def terminate(_reason, _state), do: :ok
  end
end
