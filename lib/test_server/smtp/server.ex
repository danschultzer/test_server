defmodule TestServer.SMTP.Server do
  @moduledoc false

  alias TestServer.SMTP.Session

  @doc false
  def start_link(instance, opts) do
    pid = spawn_link(fn -> init(instance, opts) end)
    {:ok, pid}
  end

  defp init(instance, opts) do
    port = Keyword.get(opts, :port, 0)

    tcp_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ]

    {:ok, listen_socket} = :gen_tcp.listen(port, tcp_opts)
    {:ok, actual_port} = :inet.port(listen_socket)

    send(instance, {:listening, actual_port, listen_socket})

    accept_loop(listen_socket, instance, opts)
  end

  defp accept_loop(listen_socket, instance, opts) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        {:ok, pid} = Session.start_link(socket, instance, opts)
        :gen_tcp.controlling_process(socket, pid)
        send(pid, :socket_ready)
        accept_loop(listen_socket, instance, opts)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end
end
