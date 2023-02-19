if Code.ensure_loaded?(Bandit) do
defmodule TestServer.HTTPServer.Bandit do
  @moduledoc false

  alias TestServer.WebSocket

  @behaviour TestServer.HTTPServer
  @behaviour WebSock

  @impl TestServer.HTTPServer
  def start(instance, port, scheme, options, bandit_options) do
    opts = [options[:ipfamily]] ++ options[:tls]

    thousand_islands_options =
      bandit_options
      |> Keyword.get(:options, [])
      |> Keyword.put(:port, port)
      |> Keyword.update(:transport_options, opts, & &1 ++ opts)

    bandit_options =
      bandit_options
      |> Keyword.put(:options, thousand_islands_options)
      |> Keyword.put(:plug, {TestServer.Plug, {__MODULE__, [], instance}})
      |> Keyword.put(:scheme, scheme)

    case Bandit.start_link(bandit_options) do
      {:ok, server_pid} -> {:ok, server_pid, bandit_options}
      {:error, error} -> {:error, error}
    end
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

  @impl WebSock
  def terminate(_reason, _state), do: :ok
end
end
