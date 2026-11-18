defmodule TestServer.HTTP.Server.HttpdTest do
  use ExUnit.Case
  doctest TestServer.HTTP.Server.Httpd

  setup context do
    TestServer.HTTP.start!(
      scheme: Map.get(context, :scheme, :http),
      http_server: {TestServer.HTTP.Server.Httpd, []},
      ipfamily: Map.get(context, :ipfamily, :inet)
    )

    :ok
  end

  describe "conn/1" do
    test "with no host header" do
      TestServer.HTTP.handle(
        to: fn conn ->
          refute List.keyfind(conn.req_headers, "host", 0)
          assert conn.host == ""
          assert conn.port == 80

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url(), [], nil, version: ~c"HTTP/1.0")
    end

    test "with host header without port" do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.host == "localhost"
          assert conn.port == 80

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url(), [{"Host", "localhost"}])
    end

    @tag scheme: :https
    test "with TLS with host header without port" do
      url = TestServer.HTTP.url()
      options = [ssl: tls_options(TestServer.HTTP.cacerts())]

      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.host == "localhost"
          assert conn.port == 443

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, url, [{"Host", "localhost"}], nil, options)
    end

    test "with host header with invalid port" do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.host == "localhost"
          assert conn.port == 80

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url(), [{"Host", "localhost:invalid"}])
    end

    test "with host header with extra colon" do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.host == "localhost"
          assert conn.port == 80

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url(), [{"Host", "localhost:8080:8081"}])
    end

    @tag ipfamily: :inet6
    test "with IPv6 host header" do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.host == "::1"
          assert conn.port == 8080

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url(), [{"Host", "[::1]:8080"}])
    end

    @tag ipfamily: :inet6
    test "with IPv6 host header without port" do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.host == "::1"
          assert conn.port == 80

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url(), [{"Host", "[::1]"}])
    end

    test "with extra query segment" do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.query_string == "foo=bar?foo=baz"

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:get, TestServer.HTTP.url("/?foo=bar?foo=baz"))
    end

    test "with UTF-8 request header and body" do
      header = "héllo 👋"
      body = "héllo 👋"

      TestServer.HTTP.handle(
        to: fn conn ->
          assert Plug.Conn.get_req_header(conn, "x-name") == [header]
          assert {:ok, ^body, conn} = Plug.Conn.read_body(conn)

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} =
               http_request(:post, TestServer.HTTP.url(), [{"x-name", header}], body)
    end

    test "builds conn" do
      url = TestServer.HTTP.url("/a//1?foo=bar")
      %{port: port} = URI.parse(url)

      TestServer.HTTP.handle("/a/1",
        to: fn conn ->
          assert conn.host == "localhost"
          assert conn.method == "GET"
          assert conn.path_info == ["a", "1"]
          assert conn.port == port
          assert conn.remote_ip == {127, 0, 0, 1}
          assert conn.query_string == "foo=bar"
          assert conn.scheme == :http
          assert Plug.Conn.get_req_header(conn, "host") == ["localhost:#{port}"]
          assert conn.request_path

          assert peer_data = Plug.Conn.get_peer_data(conn)
          assert peer_data.address == {127, 0, 0, 1}
          assert peer_data.port > 0
          assert peer_data.ssl_cert == nil

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} = http_request(:get, url)
    end

    @tag scheme: :https
    test "with TLS" do
      url = TestServer.HTTP.url()
      options = [ssl: tls_options(TestServer.HTTP.cacerts())]

      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.scheme == :https

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} = http_request(:get, url, [], nil, options)
    end
  end

  describe "send_resp/4" do
    test "with UTF-8 response header and body" do
      header = "héllo 👋"
      body = "héllo 👋"

      TestServer.HTTP.handle(
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-name", header)
          |> Plug.Conn.resp(200, body)
        end
      )

      assert {:ok, {200, headers, ^body}} = http_request(:get, TestServer.HTTP.url())

      assert List.keyfind(headers, "content-length", 0) == {"content-length", "11"}
      assert List.keyfind(headers, "x-name", 0) == {"x-name", header}
    end
  end

  defp http_request(method, url, headers \\ [], body \\ nil, options \\ []) do
    headers =
      Enum.map(headers, fn {name, value} ->
        {:binary.bin_to_list(name), :binary.bin_to_list(value)}
      end)

    request =
      case body do
        nil -> {url, headers}
        body -> {url, headers, ~c"text/plain", body}
      end

    case :httpc.request(method, request, options, []) do
      {:ok, {{_, status_code, _}, response_headers, body}} ->
        response_headers =
          Enum.map(
            response_headers,
            &{IO.iodata_to_binary(elem(&1, 0)), IO.iodata_to_binary(elem(&1, 1))}
          )

        {:ok, {status_code, response_headers, IO.iodata_to_binary(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tls_options(cacerts) do
    [
      verify: :verify_peer,
      cacerts: cacerts,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      log_level: :warning
    ]
  end
end
