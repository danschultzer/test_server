if Code.ensure_loaded?(Bandit) do
  defmodule TestServer.HTTPServer.Bandit do
    @moduledoc false

    alias TestServer.WebSocket

    @behaviour TestServer.HTTPServer
    @behaviour WebSock

    @impl TestServer.HTTPServer
    def start(instance, port, scheme, options, bandit_options) do
      transport_options =
        bandit_options
        |> Keyword.get(:transport_options, [])
        |> put_tls_options(scheme, options[:tls])

      ipfamily_opts =
        case options[:ipfamily] do
          :inet -> []
          ipfamily -> [ipfamily]
        end

      thousand_islands_options =
        bandit_options
        |> Keyword.get(:thousand_island_options, [])
        |> Keyword.put(:port, port)
        |> Keyword.put(:transport_options, ipfamily_opts ++ transport_options)

      bandit_options =
        bandit_options
        |> Keyword.put(:thousand_island_options, thousand_islands_options)
        |> Keyword.put(:plug, {TestServer.HTTPServer.Bandit.Plug, {__MODULE__, [], instance}})
        |> Keyword.put(:scheme, scheme)
        |> Keyword.put_new(:startup_log, false)

      case Bandit.start_link(bandit_options) do
        {:ok, server_pid} -> {:ok, server_pid, bandit_options}
        {:error, error} -> {:error, error}
      end
    end

    defp put_tls_options(transport_options, :http, _tls_options), do: transport_options

    defp put_tls_options(transport_options, :https, tls_options) do
      Keyword.merge(transport_options, Keyword.put_new(tls_options, :log_level, :warning))
    end

    @impl TestServer.HTTPServer
    def stop(server_pid, _bandit_options) do
      ThousandIsland.stop(server_pid)
    end

    @impl TestServer.HTTPServer
    def get_socket_pid(conn), do: conn.owner

    # WebSocket

    @impl WebSock
    def init({socket, state}) do
      {:ok, {socket, state}}
    end

    @impl WebSock
    def handle_in({data, opcode: opcode}, {socket, state}),
      do: WebSocket.handle_frame({opcode, data}, {socket, state})

    @impl WebSock
    def handle_info({callback, stacktrace}, {socket, state}),
      do: WebSocket.handle_info({callback, stacktrace}, {socket, state})

    def handle_info(_, {socket, state}), do: {:ok, {socket, state}}

    @impl WebSock
    def terminate(_reason, _state), do: :ok
  end
end
