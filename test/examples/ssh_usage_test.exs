defmodule MyApp.SSH do
  @moduledoc false

  # A minimal SSH client — the kind of module a library consumer would write
  # and want to test against TestServer.SSH.
  def run(host, port, command, opts \\ []) do
    user = Keyword.get(opts, :user, "deploy")
    password = Keyword.get(opts, :password)

    connect_opts =
      [
        user: String.to_charlist(user),
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false
      ]
      |> then(fn o ->
        if password, do: Keyword.put(o, :password, String.to_charlist(password)), else: o
      end)

    with {:ok, conn} <- :ssh.connect(String.to_charlist(host), port, connect_opts) do
      {:ok, ch} = :ssh_connection.session_channel(conn, :infinity)
      :success = :ssh_connection.exec(conn, ch, String.to_charlist(command), :infinity)
      result = collect(ch, {0, "", ""})
      :ssh.close(conn)
      result
    end
  end

  defp collect(ch, {code, out, err}) do
    receive do
      {:ssh_cm, _, {:data, ^ch, 0, data}} -> collect(ch, {code, out <> data, err})
      {:ssh_cm, _, {:data, ^ch, 1, data}} -> collect(ch, {code, out, err <> data})
      {:ssh_cm, _, {:exit_status, ^ch, c}} -> collect(ch, {c, out, err})
      {:ssh_cm, _, {:closed, ^ch}} -> {:ok, code, out, err}
    after
      5_000 -> {:error, :timeout}
    end
  end
end

defmodule MyApp.SSHUsageTest do
  use ExUnit.Case

  # Demonstrates the intended public API of TestServer.SSH from a consumer's perspective.

  test "runs a remote command and returns output" do
    TestServer.SSH.exec(to: fn "deploy", state -> {:reply, {0, "deployed v1.0\n", ""}, state} end)
    {host, port} = TestServer.SSH.address()
    assert {:ok, 0, "deployed v1.0\n", ""} = MyApp.SSH.run(host, port, "deploy")
  end

  test "propagates non-zero exit codes" do
    TestServer.SSH.exec(to: fn _, state -> {:reply, {1, "", "permission denied\n"}, state} end)
    {host, port} = TestServer.SSH.address()
    assert {:ok, 1, "", "permission denied\n"} = MyApp.SSH.run(host, port, "restricted")
  end

  test "sequential deploys consume handlers in FIFO order" do
    TestServer.SSH.exec(to: fn _, state -> {:reply, {0, "deploy 1\n", ""}, state} end)
    TestServer.SSH.exec(to: fn _, state -> {:reply, {0, "deploy 2\n", ""}, state} end)
    {host, port} = TestServer.SSH.address()
    assert {:ok, 0, "deploy 1\n", ""} = MyApp.SSH.run(host, port, "deploy")
    assert {:ok, 0, "deploy 2\n", ""} = MyApp.SSH.run(host, port, "deploy")
  end

  test "accepts client with correct password" do
    {:ok, instance} = TestServer.SSH.start(credentials: [{"deploy", "hunter2"}])
    TestServer.SSH.exec(instance, to: fn _, state -> {:reply, {0, "ok\n", ""}, state} end)
    {host, port} = TestServer.SSH.address(instance)

    assert {:ok, 0, "ok\n", ""} =
             MyApp.SSH.run(host, port, "deploy", user: "deploy", password: "hunter2")
  end

  test "rejects client with wrong password" do
    {:ok, _instance} = TestServer.SSH.start(credentials: [{"deploy", "hunter2"}])
    {host, port} = TestServer.SSH.address()
    assert {:error, _} = MyApp.SSH.run(host, port, "anything", user: "deploy", password: "wrong")
  end
end
