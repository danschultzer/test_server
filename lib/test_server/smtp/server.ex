defmodule TestServer.SMTP.Server do
  @moduledoc false

  alias TestServer.SMTP.Session

  @doc false
  @spec start(pid(), keyword()) :: {:ok, keyword()} | {:error, any()}
  def start(instance, options) do
    port = TestServer.open_port(options)
    hostname = Keyword.get(options, :hostname, "localhost")
    tls_options = Keyword.get(options, :tls_options, [])

    tcp_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ]

    case :gen_tcp.listen(port, tcp_opts) do
      {:ok, listen_socket} ->
        {:ok, actual_port} = :inet.port(listen_socket)

        session_opts = [hostname: hostname, tls_options: tls_options]
        spawn_link(fn -> accept_loop(listen_socket, instance, session_opts) end)

        options =
          options
          |> Keyword.put(:port, actual_port)
          |> Keyword.put(:hostname, hostname)
          |> Keyword.put(:listen_socket, listen_socket)

        {:ok, options}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec stop(keyword()) :: :ok
  def stop(options) do
    listen_socket = Keyword.fetch!(options, :listen_socket)
    :gen_tcp.close(listen_socket)

    :ok
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
