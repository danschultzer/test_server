defmodule TestServer.SSHClient do
  @moduledoc false

  @default_opts [
    silently_accept_hosts: true,
    user: ~c"test",
    password: ~c"test",
    user_interaction: false
  ]

  @doc """
  Connect to an SSH server.

  Accepts host as string or charlist, port, and optional SSH connect options.
  """
  def connect(host, port, opts \\ []) do
    host = if is_binary(host), do: String.to_charlist(host), else: host
    opts = Keyword.merge(@default_opts, opts)

    :ssh.connect(host, port, opts)
  end

  @doc """
  Execute a command on an SSH connection.

  Opens a channel, executes the command, collects stdout/stderr and exit code,
  then returns `{exit_code, stdout, stderr}`.
  """
  def exec(conn, command, timeout \\ 5000) do
    {:ok, channel_id} = :ssh_connection.session_channel(conn, timeout)
    :success = :ssh_connection.exec(conn, channel_id, String.to_charlist(command), timeout)

    collect_exec_response(conn, channel_id, "", "", 0, timeout)
  end

  defp collect_exec_response(conn, channel_id, stdout, stderr, exit_code, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel_id, 0, data}} ->
        collect_exec_response(conn, channel_id, stdout <> data, stderr, exit_code, timeout)

      {:ssh_cm, ^conn, {:data, ^channel_id, 1, data}} ->
        collect_exec_response(conn, channel_id, stdout, stderr <> data, exit_code, timeout)

      {:ssh_cm, ^conn, {:exit_status, ^channel_id, code}} ->
        collect_exec_response(conn, channel_id, stdout, stderr, code, timeout)

      {:ssh_cm, ^conn, {:eof, ^channel_id}} ->
        collect_exec_response(conn, channel_id, stdout, stderr, exit_code, timeout)

      {:ssh_cm, ^conn, {:closed, ^channel_id}} ->
        {exit_code, stdout, stderr}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Open a shell channel on an SSH connection.

  Returns `{:ok, conn, channel_id}`.
  """
  def open_shell(conn, timeout \\ 5000) do
    {:ok, channel_id} = :ssh_connection.session_channel(conn, timeout)
    :ok = :ssh_connection.shell(conn, channel_id)

    {:ok, conn, channel_id}
  end

  @doc """
  Send data to a shell channel.
  """
  def send_shell(conn, channel_id, data) do
    :ssh_connection.send(conn, channel_id, data)
  end

  @doc """
  Receive data from a shell channel.

  Returns `{:ok, data}` or `{:error, :timeout}`.
  """
  def recv_shell(conn, channel_id, timeout \\ 1000) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel_id, 0, data}} ->
        {:ok, to_string(data)}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Close an SSH connection.
  """
  def close(conn) do
    :ssh.close(conn)
  end
end
