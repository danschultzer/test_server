defmodule TestServer.HTTP.Server.Bandit.PlugTest do
  use ExUnit.Case

  setup do
    {:ok, _} = Application.ensure_all_started(:bandit)
    _instance = TestServer.HTTP.start!(http_server: {TestServer.HTTP.Server.Bandit, []})

    # Ensure both requests use the same HTTP/1 connection.
    pools = %{default: [protocols: [:http1], size: 1]}
    {:ok, _pid} = Finch.start_link(name: __MODULE__.Finch, pools: pools)

    :ok
  end

  test "with keep-alive connection when ignoring conn returned from `Plug.Conn.read_body/2`" do
    test_pid = self()

    TestServer.HTTP.handle("/test1",
      to: fn conn ->
        send(test_pid, {:read_body, "/test1"})

        assert {:more, body, _updated_conn} = Plug.Conn.read_body(conn, length: 1)

        Plug.Conn.resp(conn, 200, body)
      end
    )

    TestServer.HTTP.handle("/test2",
      to: fn conn ->
        assert {:ok, body, _updated_conn} = Plug.Conn.read_body(conn)

        Plug.Conn.resp(conn, 200, body)
      end
    )

    assert {:ok, %{status: 200, body: "b"}} = stream_request("/test1", "body1")
    assert {:ok, %{status: 200, body: "body2"}} = request("/test2", "body2")
  end

  defp stream_request(path, body) do
    # Delay the body until `Plug.Conn.read_body.read_body/2` calls so we ensure
    # the adapter state is only available in the uypdated conn.
    stream =
      Stream.map([body], fn body ->
        assert_receive {:read_body, ^path}

        body
      end)

    request(path, {:stream, stream})
  end

  defp request(path, body) do
    :post
    |> Finch.build(TestServer.HTTP.url(path), [{"connection", "keep-alive"}], body)
    |> Finch.request(__MODULE__.Finch)
  end
end
