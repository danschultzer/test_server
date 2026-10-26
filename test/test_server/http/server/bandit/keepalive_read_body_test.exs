defmodule TestServer.HTTP.Server.Bandit.AdapterTest.KeepaliveReadBodyTest do
  use ExUnit.Case

  setup do
    Application.ensure_all_started(:bandit)

    TestServer.HTTP.start!(http_server: {TestServer.HTTP.Server.Bandit, []})

    {:ok, socket} = connect()
    on_exit(fn -> :gen_tcp.close(socket) end)

    [socket: socket]
  end

  test "in TestServer.add discarding the conn returned by read_body does not corrupt the next keep-alive request",
       %{socket: socket} do
    for path <- ["/test1", "/test2"] do
      TestServer.HTTP.handle(path,
        to: fn conn ->
          assert {:ok, body, _conn} = Plug.Conn.read_body(conn)
          Plug.Conn.resp(conn, 200, body)
        end
      )
    end

    assert {200, "body1"} = request(socket, "/test1", "body1")
    assert {200, "body2"} = request(socket, "/test2", "body2")
  end

  # Headers and body are written as separate socket writes: the body is not in
  # Bandit's read buffer when the request headers are parsed, so the stale
  # adapter state (unread content length) can only be satisfied from the wire.
  defp request(socket, path, body) do
    head = """
    POST #{path} HTTP/1.1\r
    host: localhost\r
    content-length: #{byte_size(body)}\r
    connection: keep-alive\r
    \r
    """

    :ok = :gen_tcp.send(socket, head)
    # let the server process only the headers before sending the body
    Process.sleep(50)
    :ok = :gen_tcp.send(socket, body)

    read_response(socket)
  end

  defp connect do
    %URI{host: host, port: port} = URI.parse(TestServer.HTTP.url())

    :gen_tcp.connect(
      String.to_charlist(host),
      port,
      [:binary, active: false],
      5_000
    )
  end

  defp read_response(socket, code \\ nil, length \\ nil) do
    :ok = :inet.setopts(socket, packet: :http_bin)

    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_response, _, code, _}} ->
        read_response(socket, code, nil)

      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        read_response(socket, code, String.to_integer(value))

      {:ok, {:http_header, _, _, name, _value}}
      when name in ["date", "vary", "cache-control", "connection"] ->
        read_response(socket, code, length)

      {:ok, :http_eoh} ->
        :ok = :inet.setopts(socket, packet: :raw)
        body = read_exact(socket, "", length)
        {code, body}
    end
  end

  defp read_exact(_socket, buffer, length)
       when is_integer(length) and byte_size(buffer) >= length,
       do: binary_part(buffer, 0, length)

  defp read_exact(socket, buffer, length) do
    read_size = if length == nil, do: 0, else: length - byte_size(buffer)

    case :gen_tcp.recv(socket, read_size, 5_000) do
      {:ok, data} -> read_exact(socket, buffer <> data, length)
      {:error, :closed} when length == nil -> buffer
    end
  end
end
