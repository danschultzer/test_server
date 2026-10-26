defmodule TestServer.HTTP.Server.Bandit.AdapterTest do
  use ExUnit.Case

  setup do
    {:ok, _} = Application.ensure_all_started(:bandit)

    TestServer.HTTP.start!(scheme: :https, http_server: {TestServer.HTTP.Server.Bandit, []})

    :ok
  end

  test "Plug.Conn.send_resp/3" do
    TestServer.HTTP.handle(
      to: fn conn ->
        Plug.Conn.send_resp(conn, 200, "test")
      end
    )

    assert http2_request(TestServer.HTTP.url()) == {:ok, "test"}
  end

  test "Plug.Conn.send_file/1" do
    TestServer.HTTP.handle(
      to: fn conn ->
        Plug.Conn.send_file(conn, 200, __ENV__.file)
      end
    )

    expected = File.read!(__ENV__.file)

    assert {:ok, ^expected} = http2_request(TestServer.HTTP.url())
  end

  test "Plug.Conn.send_chunked/1 and Plug.Conn.chunk/1" do
    TestServer.HTTP.handle(
      to: fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "Hello\n")
        {:ok, conn} = Plug.Conn.chunk(conn, "World")

        conn
      end
    )

    assert http2_request(TestServer.HTTP.url()) == {:ok, "Hello\nWorld"}
  end

  test "Plug.Conn.get_peer_data/1" do
    TestServer.HTTP.handle(
      to: fn conn ->
        assert %{address: {127, 0, 0, 1}} = Plug.Conn.get_peer_data(conn)

        Plug.Conn.resp(conn, 200, "OK")
      end
    )

    assert http2_request(TestServer.HTTP.url()) == {:ok, "OK"}
  end

  test "Plug.Conn.get_http_protocol/1" do
    TestServer.HTTP.handle(
      to: fn conn ->
        assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
        Plug.Conn.send_resp(conn, 200, "OK")
      end
    )

    assert http2_request(TestServer.HTTP.url()) == {:ok, "OK"}
  end

  test "Plug.Conn.read_body/1" do
    TestServer.HTTP.handle(
      to: fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)

        Plug.Conn.resp(conn, 200, body)
      end
    )

    assert http2_request(TestServer.HTTP.url(), method: :post, body: "test") == {:ok, "test"}
  end

  test "Plug.Conn.read_body/2 when returning `:more`" do
    TestServer.HTTP.handle("/",
      to: fn conn ->
        assert {:more, body, conn} = Plug.Conn.read_body(conn, length: 1)
        assert {:ok, rest, conn} = Plug.Conn.read_body(conn)

        Plug.Conn.resp(conn, 200, body <> rest)
      end
    )

    assert http2_request(TestServer.HTTP.url(), method: :post, body: "test") == {:ok, "test"}
  end

  defp http2_request(url, options \\ []) do
    pools = %{
      default: [
        protocols: [:http2],
        conn_opts: [transport_opts: [cacerts: TestServer.HTTP.cacerts()]]
      ]
    }

    unless Process.whereis(__MODULE__.Finch) do
      {:ok, _pid} = Finch.start_link(name: __MODULE__.Finch, pools: pools)
    end

    headers = Keyword.get(options, :headers, [])
    body = Keyword.get(options, :body, nil)

    options
    |> Keyword.get(:method, :get)
    |> Finch.build(url, headers, body)
    |> Finch.request(__MODULE__.Finch)
    |> case do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: _, body: body}} ->
        {:error, body}

      {:error, %Finch.Error{reason: :pool_not_available}} ->
        :timer.sleep(10)

        http2_request(url, options)

      {:error, error} ->
        {:error, error}
    end
  end
end
