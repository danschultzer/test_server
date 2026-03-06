defmodule TestServer.SSHClient do
  @moduledoc false

  def connect(host, port, opts \\ []) do
    defaults = [
      user_interaction: false,
      silently_accept_hosts: true,
      save_accepted_host: false
    ]

    :ssh.connect(String.to_charlist(host), port, Keyword.merge(defaults, opts))
  end

  def exec(conn, command) do
    {:ok, ch} = :ssh_connection.session_channel(conn, :infinity)
    :success = :ssh_connection.exec(conn, ch, String.to_charlist(command), :infinity)
    collect_exec(ch, {0, "", ""})
  end

  def open_shell(conn) do
    {:ok, ch} = :ssh_connection.session_channel(conn, :infinity)
    :ok = :ssh_connection.shell(conn, ch)
    ch
  end

  def send(conn, ch, data) do
    :ssh_connection.send(conn, ch, data)
  end

  def recv(ch, timeout \\ 5_000) do
    receive do
      {:ssh_cm, _, {:data, ^ch, 0, data}} -> {:ok, data}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp collect_exec(ch, {code, out, err}) do
    receive do
      {:ssh_cm, _, {:data, ^ch, 0, data}} -> collect_exec(ch, {code, out <> data, err})
      {:ssh_cm, _, {:data, ^ch, 1, data}} -> collect_exec(ch, {code, out, err <> data})
      {:ssh_cm, _, {:exit_status, ^ch, c}} -> collect_exec(ch, {c, out, err})
      {:ssh_cm, _, {:closed, ^ch}} -> {code, out, err}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
