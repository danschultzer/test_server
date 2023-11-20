defmodule TestServer.HTTPServer.Bandit.HTTP2AdapterTest do
  use ExUnit.Case
  doctest TestServer

  setup do
    Application.ensure_all_started(:bandit)

    {:ok, _instance} =
      TestServer.start(scheme: :https, http_server: {TestServer.HTTPServer.Bandit, []})

    :ok
  end

  test "Plug.Conn.send_resp/3" do
    assert :ok =
             TestServer.add("/",
               to: fn conn ->
                 Plug.Conn.send_resp(conn, 200, "test")
               end
             )

    assert {:ok, "test"} = http2_request(TestServer.url())
  end

  test "Plug.Conn.send_file/1" do
    assert :ok =
             TestServer.add("/",
               to: fn conn ->
                 Plug.Conn.send_file(conn, 200, __ENV__.file)
               end
             )

    expected = File.read!(__ENV__.file)

    assert {:ok, ^expected} = http2_request(TestServer.url())
  end

  test "Plug.Conn.send_chunked/1 and Plug.Conn.chunk/1" do
    assert :ok =
             TestServer.add("/",
               to: fn conn ->
                 conn = Plug.Conn.send_chunked(conn, 200)
                 {:ok, conn} = Plug.Conn.chunk(conn, "Hello\n")
                 {:ok, conn} = Plug.Conn.chunk(conn, "World")

                 conn
               end
             )

    assert {:ok, "Hello\nWorld"} = http2_request(TestServer.url())
  end

  test "Plug.Conn.get_peer_data/1" do
    assert :ok =
             TestServer.add("/",
               to: fn conn ->
                 assert %{address: {127, 0, 0, 1}} = Plug.Conn.get_peer_data(conn)

                 Plug.Conn.resp(conn, 200, "OK")
               end
             )

    assert {:ok, "OK"} = http2_request(TestServer.url())
  end

  test "Plug.Conn.get_http_protocol/1" do
    assert :ok =
             TestServer.add("/",
               to: fn conn ->
                 assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
                 Plug.Conn.send_resp(conn, 200, "OK")
               end
             )

    assert {:ok, "OK"} = http2_request(TestServer.url())
  end

  test "Plug.Conn.read_body/1" do
    assert :ok =
             TestServer.add("/",
               to: fn conn ->
                 assert {:ok, body, _data} = Plug.Conn.read_body(conn)
                 Plug.Conn.resp(conn, 200, body)
               end
             )

    assert {:ok, "test"} = http2_request(TestServer.url(), method: :post, body: "test")
  end

  defp http2_request(url, opts \\ []) do
    pools = %{
      default: [
        protocol: :http2,
        conn_opts: [transport_opts: [cacerts: TestServer.x509_suite().cacerts]]
      ]
    }

    unless Process.whereis(Finch) do
      {:ok, _pid} = Finch.start_link(name: Finch, pools: pools)
    end

    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, nil)

    opts
    |> Keyword.get(:method, :get)
    |> Finch.build(url, headers, body)
    |> Finch.request(Finch)
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: _, body: body}} -> {:error, body}
      {:error, error} -> {:error, error}
    end
  end
end
