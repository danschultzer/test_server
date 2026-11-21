defmodule TestServer.HTTP.Server.HttpdTest do
  use ExUnit.Case
  doctest TestServer.HTTP.Server.Httpd

  setup context do
    ipfamily = Map.get(context, :ipfamily, :inet)

    TestServer.HTTP.start!(
      scheme: Map.get(context, :scheme, :http),
      http_server: {TestServer.HTTP.Server.Httpd, Map.get(context, :http_server_options, [])},
      ipfamily: Map.get(context, :ipfamily, :inet)
    )

    :httpc.set_options(ipfamily: ipfamily)

    :ok
  end

  describe "conn/1" do
    test "with no host header" do
      TestServer.HTTP.handle(
        to: fn conn ->
          refute List.keyfind(conn.req_headers, "host", 0)
          assert conn.host == ""
          assert conn.port == 80
          assert Plug.Conn.get_http_protocol(conn) == :"HTTP/1.0"

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
          refute peer_data.ssl_cert

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, {200, _headers, "OK"}} = http_request(:get, url)
    end

    @tag http_server_options: [socket_type: {:ip_comm, [protocol: :tcp]}]
    test "with `socket_type: {:ip_comm, options}`" do
      url = TestServer.HTTP.url()

      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.scheme == :http

          assert peer_data = Plug.Conn.get_peer_data(conn)
          assert peer_data.port > 0

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

          assert peer_data = Plug.Conn.get_peer_data(conn)
          assert peer_data.ssl_cert

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

    test "with 204 response" do
      TestServer.HTTP.handle(to: fn conn -> Plug.Conn.resp(conn, 204, "") end)

      assert {:ok, {204, headers, ""}} = http_request(:get, TestServer.HTTP.url())
      refute List.keyfind(headers, "content-length", 0)
    end

    test "with 304 response" do
      TestServer.HTTP.handle(
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-length", "1")
          |> Plug.Conn.resp(304, "")
        end
      )

      assert {:ok, {304, headers, ""}} = http_request(:get, TestServer.HTTP.url())
      assert List.keyfind(headers, "content-length", 0) == {"content-length", "1"}
    end

    test "with content-length header" do
      TestServer.HTTP.handle(
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-length", "123")
          |> Plug.Conn.resp(200, "OK")
        end
      )

      assert {:ok, {200, headers, "OK"}} = http_request(:get, TestServer.HTTP.url())
      assert List.keyfind(headers, "content-length", 0) == {"content-length", "2"}
    end
  end

  describe "send_file/3" do
    setup do
      path = __ENV__.file
      content = File.read!(__ENV__.file)

      {:ok, path: path, content: content}
    end

    test "with `0` offset and `:all` length", %{path: path, content: content} do
      length = byte_size(content)

      TestServer.HTTP.handle(to: fn conn -> Plug.Conn.send_file(conn, 200, path) end)

      assert {:ok, {200, headers, ^content}} = http_request(:get, TestServer.HTTP.url())
      assert List.keyfind(headers, "content-length", 0) == {"content-length", to_string(length)}
    end

    @tag :tmp_dir
    test "with an empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty")
      File.write!(path, "")

      TestServer.HTTP.handle(to: fn conn -> Plug.Conn.send_file(conn, 200, path) end)

      assert {:ok, {200, headers, ""}} = http_request(:get, TestServer.HTTP.url())
      assert List.keyfind(headers, "content-length", 0) == {"content-length", "0"}
    end

    test "with `offset` < 0", %{path: path} do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert_raise ArgumentError, ~r/expected offset to be 0 or greater/, fn ->
            Plug.Conn.send_file(conn, 200, path, -1)
          end

          Plug.Conn.send_resp(conn, 200, "")
        end
      )

      assert {:ok, {200, _headers, ""}} = http_request(:get, TestServer.HTTP.url())
    end

    test "with `offset` > content size", %{path: path, content: content} do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert_raise ArgumentError,
                       ~r/expected offset to be content size or less/,
                       fn ->
                         Plug.Conn.send_file(conn, 200, path, byte_size(content) + 1)
                       end

          Plug.Conn.send_resp(conn, 200, "")
        end
      )

      assert {:ok, {200, _headers, ""}} = http_request(:get, TestServer.HTTP.url())
    end

    test "with `offset`", %{path: path, content: content} do
      length = byte_size(content) - 1
      expected_content = :binary.part(content, 1, length)

      TestServer.HTTP.handle(to: fn conn -> Plug.Conn.send_file(conn, 200, path, 1) end)

      assert {:ok, {200, headers, ^expected_content}} = http_request(:get, TestServer.HTTP.url())
      assert List.keyfind(headers, "content-length", 0) == {"content-length", to_string(length)}
    end

    test "with `length` < 0", %{path: path} do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert_raise ArgumentError,
                       "expected length to be 0 or greater",
                       fn ->
                         Plug.Conn.send_file(conn, 200, path, 0, -1)
                       end

          Plug.Conn.send_resp(conn, 200, "")
        end
      )

      assert {:ok, {200, _headers, ""}} = http_request(:get, TestServer.HTTP.url())
    end

    test "with `length` > content size", %{path: path, content: content} do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert_raise ArgumentError,
                       "expected length to be content size or less",
                       fn ->
                         Plug.Conn.send_file(conn, 200, path, 0, byte_size(content) + 1)
                       end

          Plug.Conn.send_resp(conn, 200, "")
        end
      )

      assert {:ok, {200, _headers, ""}} = http_request(:get, TestServer.HTTP.url())
    end

    test "with `length` > content size - `offset`", %{path: path, content: content} do
      TestServer.HTTP.handle(
        to: fn conn ->
          assert_raise ArgumentError,
                       ~r/expected length to be content size - offset or less/,
                       fn ->
                         Plug.Conn.send_file(conn, 200, path, 10, byte_size(content) - 9)
                       end

          Plug.Conn.send_resp(conn, 200, "")
        end
      )

      assert {:ok, {200, _headers, ""}} = http_request(:get, TestServer.HTTP.url())
    end

    test "with `length`", %{path: path, content: content} do
      expected_content = :binary.part(content, 0, 10)

      TestServer.HTTP.handle(to: fn conn -> Plug.Conn.send_file(conn, 200, path, 0, 10) end)

      assert {:ok, {200, _headers, ^expected_content}} = http_request(:get, TestServer.HTTP.url())
    end
  end

  test "send_chunked/2" do
    TestServer.HTTP.handle(
      to: fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, ["Hello", ?\n])
        {:ok, conn} = Plug.Conn.chunk(conn, "World")

        conn
      end
    )

    assert {:ok, {200, _headers, "Hello\nWorld"}} = http_request(:get, TestServer.HTTP.url())
  end

  test "get_http_protocol/1" do
    TestServer.HTTP.handle(
      to: fn conn ->
        assert Plug.Conn.get_http_protocol(conn) == :"HTTP/1.1"

        Plug.Conn.send_resp(conn, 200, "")
      end
    )

    assert {:ok, {200, _headers, ""}} = http_request(:get, TestServer.HTTP.url())
  end

  test "read_req_body/2" do
    TestServer.HTTP.handle(
      to: fn conn ->
        {:more, body, conn} = Plug.Conn.read_body(conn, length: 1)
        assert body == "r"
        {:more, body, conn} = Plug.Conn.read_body(conn, length: 2)
        assert body == "eq"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "uest body"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == ""

        Plug.Conn.send_resp(conn, 200, "")
      end
    )

    assert {:ok, {200, _headers, ""}} =
             http_request(:post, TestServer.HTTP.url(), [], "request body")
  end

  test "inform/3" do
    TestServer.HTTP.handle(
      to: fn conn ->
        Plug.Conn.inform(conn, 100, [{"x-early-hints", "Link"}])
        Plug.Conn.resp(conn, 200, "OK")
      end
    )

    assert {:ok, {200, _headers, "OK"}} = http_request(:get, TestServer.HTTP.url())
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
