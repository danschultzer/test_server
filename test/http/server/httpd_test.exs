defmodule TestServer.HTTP.Server.HttpdTest do
  use ExUnit.Case

  setup context do
    {:ok, _instance} =
      TestServer.HTTP.start(
        scheme: :http,
        http_server: {TestServer.HTTP.Server.Httpd, []},
        ipfamily: context[:ipfamily] || :inet
      )

    :ok
  end

  describe "conn/1" do
    test "with no host header" do
      assert :ok =
               TestServer.HTTP.add("/",
                 to: fn conn ->
                   refute List.keyfind(conn.req_headers, "host", 0)
                   assert conn.host == ""
                   refute conn.port

                   Plug.Conn.resp(conn, 200, "OK")
                 end
               )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url("/"), [], version: ~c"HTTP/1.0")
    end

    test "with host header without port" do
      assert :ok =
               TestServer.HTTP.add("/",
                 to: fn conn ->
                   assert conn.host == "localhost"
                   refute conn.port

                   Plug.Conn.resp(conn, 200, "OK")
                 end
               )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url("/"), [{"Host", "localhost"}])
    end

    test "with host header with invalid port" do
      assert :ok =
               TestServer.HTTP.add("/",
                 to: fn conn ->
                   assert conn.host == "localhost"
                   refute conn.port

                   Plug.Conn.resp(conn, 200, "OK")
                 end
               )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url("/"), [{"Host", "localhost:invalid"}])
    end

    test "with host header with extra colon" do
      assert :ok =
               TestServer.HTTP.add("/",
                 to: fn conn ->
                   assert conn.host == "localhost"
                   refute conn.port

                   Plug.Conn.resp(conn, 200, "OK")
                 end
               )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url("/"), [{"Host", "localhost:8080:8081"}])
    end

    @tag ipfamily: :inet6
    test "with IPv6 host header" do
      assert :ok =
               TestServer.HTTP.add("/",
                 to: fn conn ->
                   assert conn.host == "::1"
                   assert conn.port == 8080

                   Plug.Conn.resp(conn, 200, "OK")
                 end
               )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url("/"), [{"Host", "[::1]:8080"}])
    end

    @tag ipfamily: :inet6
    test "with IPv6 host header without port" do
      assert :ok =
               TestServer.HTTP.add("/",
                 to: fn conn ->
                   assert conn.host == "::1"
                   refute conn.port

                   Plug.Conn.resp(conn, 200, "OK")
                 end
               )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url("/"), [{"Host", "[::1]"}])
    end

    test "with extra query segment" do
      assert :ok =
               TestServer.HTTP.add("/",
                 to: fn conn ->
                   assert conn.query_string == "foo=bar"

                   Plug.Conn.resp(conn, 200, "OK")
                 end
               )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url("/?foo=bar?foo=baz"))
    end

    test "builds conn" do
      url = TestServer.HTTP.url("/a//1?foo=bar")
      %{port: port} = URI.parse(url)

      assert :ok =
               TestServer.HTTP.add("/a/1",
                 to: fn conn ->
                   assert conn.host == "localhost"
                   assert conn.method == "GET"
                   assert conn.path_info == ["a", "1"]
                   assert conn.port == port
                   assert conn.remote_ip == {127, 0, 0, 1}
                   assert conn.query_string == "foo=bar"

                   assert List.keyfind(conn.req_headers, "host", 0) ==
                            {"host", "localhost:#{port}"}

                   assert conn.request_path
                   refute conn.scheme

                   Plug.Conn.resp(conn, 200, "OK")
                 end
               )

      assert {:ok, {200, _headers, "OK"}} = http_request(:get, url)
    end
  end

  describe "send_resp/4" do
    test "with UTF-8 content" do
      body = "héllo 👋"

      assert :ok =
               TestServer.HTTP.add("/",
                 to: fn conn ->
                   Plug.Conn.resp(conn, 200, body)
                 end
               )

      assert {:ok, {200, headers, ^body}} = http_request(:get, TestServer.HTTP.url("/"))
      assert List.keyfind(headers, "content-length", 0) == {"content-length", "11"}
    end
  end

  defp http_request(method, url, headers \\ [], options \\ []) do
    url = String.to_charlist(url)

    headers =
      Enum.map(headers, &{String.to_charlist(elem(&1, 0)), String.to_charlist(elem(&1, 1))})

    case :httpc.request(method, {url, headers}, options, []) do
      {:ok, {{_, status_code, _}, response_headers, body}} ->
        response_headers =
          Enum.map(response_headers, &{to_string(elem(&1, 0)), to_string(elem(&1, 1))})

        {:ok, {status_code, response_headers, IO.iodata_to_binary(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
