defmodule TestServer.HTTPTest do
  use ExUnit.Case
  doctest TestServer.HTTP

  import ExUnit.CaptureIO

  alias __MODULE__.WebSocketClient

  describe "start/1" do
    test "with invalid `:port` option" do
      assert_raise ArgumentError, ~r/expected a port, got: :invalid/, fn ->
        TestServer.HTTP.start(port: :invalid)
      end
    end

    test "with invalid `:scheme` option" do
      assert_raise RuntimeError, ~r/Invalid scheme, got: :invalid/, fn ->
        TestServer.HTTP.start(scheme: :invalid)
      end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.HTTP.start()
      {:ok, instance_2} = TestServer.HTTP.start()

      refute instance_1 == instance_2

      options_1 = TestServer.HTTP.Instance.options(instance_1)
      options_2 = TestServer.HTTP.Instance.options(instance_2)

      refute options_1[:port] == options_2[:port]
    end

    test "with `scheme: :https` option" do
      instance = TestServer.HTTP.start!(scheme: :https)
      options = TestServer.HTTP.Instance.options(instance)

      assert Keyword.has_key?(options, :cacerts)

      valid_cacerts = TestServer.HTTP.cacerts()
      %{cacerts: invalid_cacerts} = X509.Test.Suite.new()

      assert {:error, {:failed_connect, _}} =
               http1_request(TestServer.HTTP.url(),
                 http_options: [ssl: tls_options(invalid_cacerts)]
               )

      TestServer.HTTP.handle()

      assert {:ok, _} =
               http1_request(TestServer.HTTP.url(),
                 http_options: [ssl: tls_options(valid_cacerts)]
               )
    end

    test "with `scheme: :https` option with `:tls` option with custom certificates" do
      options = TestServer.put_tls_options([])
      tls = Keyword.fetch!(options, :tls)
      cacerts = Keyword.fetch!(options, :cacerts)
      instance = TestServer.HTTP.start!(scheme: :https, tls: tls)
      options = TestServer.HTTP.Instance.options(instance)

      refute Keyword.has_key?(options, :cacerts)

      TestServer.HTTP.handle()

      assert {:ok, _response} =
               http1_request(
                 TestServer.HTTP.url(),
                 http_options: [ssl: tls_options(cacerts)]
               )
    end

    test "with `ipfamily: :inet6` option" do
      instance = TestServer.HTTP.start!(ipfamily: :inet6)
      options = TestServer.HTTP.Instance.options(instance)

      assert options[:ipfamily] == :inet6

      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.remote_ip == {0, 0, 0, 0, 0, 65_535, 32_512, 1}

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert %{host: hostname} = URI.parse(TestServer.HTTP.url())

      assert :inet.getaddr(String.to_charlist(hostname), :inet6) ==
               {:ok, {0, 0, 0, 0, 0, 0, 0, 1}}

      assert {:ok, _} = http1_request(TestServer.HTTP.url())
    end

    test "with invalid `:http_server` option" do
      assert_raise RuntimeError, ~r/Invalid http_server, got: :invalid/, fn ->
        TestServer.HTTP.start(http_server: :invalid)
      end
    end

    test "when test ends" do
      {:ok, port} = TestServer.open_port([])

      on_exit(fn ->
        refute :gen_tcp.listen(port, []) == {:error, :eaddrinuse},
               "Port #{port} must be released after test ends"
      end)

      assert {:ok, _instance} = TestServer.HTTP.start(port: port)
      assert {:error, :eaddrinuse} = :gen_tcp.listen(port, [])
    end
  end

  describe "start!/1" do
    test "returns instance" do
      assert instance = TestServer.HTTP.start!()
      assert is_pid(instance)
    end

    test "when start fails" do
      instance = TestServer.HTTP.start!()
      port = instance |> TestServer.HTTP.Instance.options() |> Keyword.fetch!(:port)

      assert_raise RuntimeError,
                   ~r/EXIT when starting TestServer.HTTP instance on port #{port}/,
                   fn -> TestServer.HTTP.start!(port: port) end
    end
  end

  describe "stop/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.HTTP.Instance running", fn ->
        TestServer.HTTP.stop()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.HTTP.start!()
                     :ok = TestServer.HTTP.stop()

                     TestServer.HTTP.stop(instance)
                   end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.HTTP.start()
      {:ok, _instance_2} = TestServer.HTTP.start()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.HTTP\.stop\/0`/,
                   fn ->
                     TestServer.HTTP.stop()
                   end

      assert TestServer.HTTP.stop(instance_1) == :ok
      assert TestServer.HTTP.stop() == :ok
    end

    test "stops" do
      instance = TestServer.HTTP.start!()
      url = TestServer.HTTP.url()

      assert TestServer.HTTP.stop() == :ok
      refute Process.alive?(instance)
      assert {:error, {:failed_connect, _}} = http1_request(url)
    end
  end

  describe "url/3" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.HTTP.Instance running", fn ->
        TestServer.HTTP.url()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.HTTP.start!()
                     :ok = TestServer.HTTP.stop()

                     TestServer.HTTP.url(instance)
                   end
    end

    test "with multiple instances" do
      instance_1 = TestServer.HTTP.start!()
      instance_2 = TestServer.HTTP.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.HTTP\.url\/2`/,
                   fn ->
                     TestServer.HTTP.url()
                   end

      refute TestServer.HTTP.url(instance_1) == TestServer.HTTP.url(instance_2)
    end

    test "returns" do
      TestServer.HTTP.start!()

      assert TestServer.HTTP.url() =~ ~r/^http\:\/\/localhost\:[0-9]+$/
      assert TestServer.HTTP.url("/path") =~ "/path"
      assert TestServer.HTTP.url(host: "example.com") =~ ~r/^http\:\/\/example\.com\:[0-9]+$/
    end

    test "with invalid `:host` option" do
      TestServer.HTTP.start!()

      assert_raise RuntimeError, ~r/Invalid host, got: :invalid/, fn ->
        TestServer.HTTP.url(host: :invalid)
      end
    end

    test "with `:host` option" do
      TestServer.HTTP.start!()

      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.remote_ip == {127, 0, 0, 1}
          assert conn.host == "custom-host"

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, _} = http1_request(TestServer.HTTP.url(host: "custom-host"))
    end

    test "with `:host` option when started with `ipfamily: :inet6` option" do
      TestServer.HTTP.start!(ipfamily: :inet6, http_server: {TestServer.HTTP.Server.Httpd, []})

      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.remote_ip == {0, 0, 0, 0, 0, 65_535, 32_512, 1}
          assert conn.host == "custom-host"

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert {:ok, _} = http1_request(TestServer.HTTP.url(host: "custom-host"))
    end
  end

  describe "handle/3" do
    test "when instance not running" do
      assert_raise RuntimeError,
                   ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.HTTP.start!()
                     :ok = TestServer.HTTP.stop(instance)

                     TestServer.HTTP.handle(instance)
                   end
    end

    test "with multiple instances" do
      instance_1 = TestServer.HTTP.start!()
      _instance_2 = TestServer.HTTP.start!()

      assert_raise RuntimeError,
                   ~r/Multiple instances running, please pass instance to `TestServer\.HTTP\.handle\/1`/,
                   fn ->
                     TestServer.HTTP.handle()
                   end

      TestServer.HTTP.handle(instance_1)

      assert {:ok, _} = http1_request(TestServer.HTTP.url(instance_1))

      TestServer.HTTP.stop(instance_1)
    end

    test "with invalid `:path` option" do
      assert_raise ArgumentError, ~r/expected a binary, got: :invalid/, fn ->
        TestServer.HTTP.handle(path: :invalid)
      end
    end

    test "with invalid `:method` option" do
      assert_raise ArgumentError, ~r/expected :method to be an atom or list, got: %{}/, fn ->
        TestServer.HTTP.handle(method: %{})
      end
    end

    test "with invalid `:match` and `:to` options" do
      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.HTTP.handle(match: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.HTTP.handle(to: :invalid)
      end
    end

    test "when receiving no requests" do
      defmodule HandleNoRequestTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.handle()
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "did not receive a request for these handlers before the test ended:"
    end

    test "when receiving unexpected request" do
      defmodule HandleUnexpectedRequestTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url("/?a=1"))
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected GET request at / with params:"
      assert io =~ "query_params: %{\"a\" => \"1\"}"
      assert io =~ "No active handlers."
      refute io =~ "The following handlers have been processed:"
    end

    test "when receiving unexpected request before all handlers are processed" do
      defmodule HandleUnexpectedRequestBeforeProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle(match: fn _conn -> false end)

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /."
      refute io =~ "No active handlers."
      refute io =~ "The following handlers have been processed:"
      assert io =~ "Active handlers:"
    end

    test "when receiving unexpected request after all handlers are processed" do
      defmodule HandleUnexpectedRequestAfterProcessedTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle()

          assert {:ok, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /."
      assert io =~ "No active handlers."
      assert io =~ "The following handlers have been processed:"
    end

    test "with path argument when path doesn't match" do
      defmodule HandlePathArgumentMismatchTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle("/path")

          assert {:error, _} =
                   unquote(__MODULE__).http1_request(TestServer.HTTP.url("/other-path"))
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /other-path."
    end

    test "with `:path` option when path doesn't match" do
      defmodule HandlePathOptionMismatchTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle(path: "/path")

          assert {:error, _} =
                   unquote(__MODULE__).http1_request(TestServer.HTTP.url("/other-path"))
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /other-path."
      assert io =~ "Active handlers:"
    end

    test "with `:method` option when method doesn't match" do
      defmodule HandleMethodMismatchTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle(method: :post)

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /."
    end

    test "with `method: []` option" do
      defmodule HandleMethodEmptyTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle(method: [])

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /."
    end

    test "with no path specified" do
      TestServer.HTTP.handle()

      assert {:ok, _} = http1_request(TestServer.HTTP.url("/path"))
    end

    test "with path argument" do
      TestServer.HTTP.handle("/1", to: &Plug.Conn.resp(&1, 200, "1"))
      TestServer.HTTP.handle("/2", to: &Plug.Conn.resp(&1, 200, "2"))

      assert http1_request(TestServer.HTTP.url("/2")) == {:ok, "2"}
      assert http1_request(TestServer.HTTP.url("/1")) == {:ok, "1"}
    end

    test "with instance and path argument" do
      instance = TestServer.HTTP.start!()
      TestServer.HTTP.handle(instance, "/path")

      assert {:ok, _} = http1_request(TestServer.HTTP.url(instance, "/path"))
    end

    test "with `:path` option" do
      TestServer.HTTP.handle(path: "/1", to: &Plug.Conn.resp(&1, 200, "1"))
      TestServer.HTTP.handle(path: "/2", to: &Plug.Conn.resp(&1, 200, "2"))

      assert http1_request(TestServer.HTTP.url("/2")) == {:ok, "2"}
      assert http1_request(TestServer.HTTP.url("/1")) == {:ok, "1"}
    end

    test "with no `:method` option" do
      TestServer.HTTP.handle()

      assert {:ok, _} = http1_request(TestServer.HTTP.url(), method: :post)
    end

    test "with an empty `:method` option" do
      TestServer.HTTP.handle(
        method: [],
        to: fn _conn ->
          flunk("Handler should not be called")
        end
      )

      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, "second"))

      assert http1_request(TestServer.HTTP.url()) == {:ok, "second"}

      TestServer.HTTP.stop()
    end

    test "with `:method` option" do
      TestServer.HTTP.handle(method: :get, to: &Plug.Conn.resp(&1, 200, ":get"))
      TestServer.HTTP.handle(method: [:post, :get], to: &Plug.Conn.resp(&1, 200, "[:post, :get]"))
      TestServer.HTTP.handle(method: :post, to: &Plug.Conn.resp(&1, 200, ":post"))

      assert http1_request(TestServer.HTTP.url(), method: :post) == {:ok, "[:post, :get]"}
      assert http1_request(TestServer.HTTP.url()) == {:ok, ":get"}
      assert http1_request(TestServer.HTTP.url(), method: :post) == {:ok, ":post"}
    end

    test "with `:to` plug" do
      defmodule HandleToPlug do
        def init(options), do: options

        def call(conn, _options), do: Plug.Conn.resp(conn, 200, to_string(__MODULE__))
      end

      TestServer.HTTP.handle(to: HandleToPlug)

      assert http1_request(TestServer.HTTP.url()) == {:ok, to_string(HandleToPlug)}
    end

    test "when `:to` function raises exception" do
      defmodule HandleToFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle(to: fn _conn -> raise "boom" end)

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.HTTPTest.HandleToFunctionRaiseTest"
    end

    test "when `:to` function halts conn" do
      defmodule HandleToFunctionHaltsTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle(to: fn conn -> Plug.Conn.halt(conn) end)

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "Do not halt a connection. All requests have to be processed."
    end

    test "with `:to` function" do
      TestServer.HTTP.handle(to: fn conn -> Plug.Conn.resp(conn, 200, "function called") end)

      assert http1_request(TestServer.HTTP.url()) == {:ok, "function called"}
    end

    test "when `:match` function raises exception" do
      defmodule HandleMatchFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.handle(match: fn _conn -> raise "boom" end)

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.HTTPTest.HandleMatchFunctionRaiseTest"
    end

    test "with `:match` function" do
      TestServer.HTTP.handle(
        match: fn
          %{params: %{"a" => "1"}} = _conn -> true
          _conn -> false
        end,
        to: &Plug.Conn.resp(&1, 200, "1")
      )

      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, "2"))

      assert http1_request(TestServer.HTTP.url() <> "?a=2") == {:ok, "2"}
      assert http1_request(TestServer.HTTP.url() <> "?a=1") == {:ok, "1"}
    end

    test "with `:match` function with `:path` and `:method` options" do
      TestServer.HTTP.handle(
        path: "/path",
        method: :post,
        match: fn
          %{params: %{"a" => "1"}} = _conn -> true
          _conn -> false
        end,
        to: &Plug.Conn.resp(&1, 200, "1")
      )

      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, "2"))

      assert http1_request(TestServer.HTTP.url("/path") <> "?a=1") == {:ok, "2"}
      assert http1_request(TestServer.HTTP.url("/path") <> "?a=1", method: :post) == {:ok, "1"}
    end

    # `:httpd` has no HTTP/2 support
    unless System.get_env("HTTP_SERVER") == "Httpd" do
      test "with HTTP/2" do
        TestServer.HTTP.start!(scheme: :https)
        TestServer.HTTP.handle()

        assert http2_request(TestServer.HTTP.url()) == {:ok, "HTTP/2"}
      end

      test "with HTTP/2 with `:to` function" do
        TestServer.HTTP.start!(scheme: :https)

        TestServer.HTTP.handle(
          to: fn conn ->
            assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
            assert {:ok, body, conn} = Plug.Conn.read_body(conn)

            Plug.Conn.resp(conn, 200, body)
          end
        )

        assert http2_request(TestServer.HTTP.url(), method: :post, body: "test") == {:ok, "test"}
      end
    end
  end

  describe "plug/2" do
    test "with invalid plug" do
      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.HTTP.plug(:invalid)
      end
    end

    test "with plug function" do
      TestServer.HTTP.plug(fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)

        %{conn | params: %{"plug" => "anonymous function", body: body}}
      end)

      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, URI.encode_query(&1.params)))

      assert {:ok, query} = http1_request(TestServer.HTTP.url(), method: :post)
      assert URI.decode_query(query) == %{"plug" => "anonymous function", "body" => "OK"}
    end

    test "with plug module" do
      defmodule ModulePlug do
        def init(options), do: options

        def call(conn, _options), do: %{conn | params: %{"plug" => to_string(__MODULE__)}}
      end

      TestServer.HTTP.plug(ModulePlug)
      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, &1.params["plug"]))

      assert http1_request(TestServer.HTTP.url()) == {:ok, to_string(ModulePlug)}
    end

    test "when plug function raises exception" do
      defmodule PlugFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.plug(fn _conn -> raise "boom" end)

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.HTTPTest.PlugFunctionRaiseTest"
    end

    test "when plug function halts conn" do
      defmodule PlugFunctionHaltsTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.start!(suppress_warning: true)
          TestServer.HTTP.plug(fn conn -> Plug.Conn.halt(conn) end)
          TestServer.HTTP.handle()

          assert {:error, _} = unquote(__MODULE__).http1_request(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "Do not halt a connection. All requests have to be processed."
    end
  end

  describe "cacerts/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.HTTP.Instance running", fn ->
        TestServer.HTTP.cacerts()
      end

      assert_raise RuntimeError,
                   ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is not running/,
                   fn ->
                     instance = TestServer.HTTP.start!()
                     :ok = TestServer.HTTP.stop()

                     TestServer.HTTP.cacerts(instance)
                   end
    end

    test "when not started with `scheme: :https` option" do
      TestServer.HTTP.start!()

      assert_raise RuntimeError,
                   ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is not running with `\[scheme: :https\]` option/,
                   fn ->
                     TestServer.HTTP.cacerts()
                   end
    end

    test "when started with `scheme: :https` option with `:tls` option with custom certificates" do
      tls_options = [] |> TestServer.put_tls_options() |> Keyword.fetch!(:tls)

      TestServer.HTTP.start!(scheme: :https, tls: tls_options)

      assert_raise RuntimeError,
                   ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is running with custom `:tls` certificate options/,
                   fn ->
                     TestServer.HTTP.cacerts()
                   end
    end
  end

  # Httpd adapter has no WebSocket support
  if System.get_env("HTTP_SERVER") == "Httpd" do
    describe "websocket/3" do
      test "returns 501" do
        # Test with WebSockex client
        TestServer.HTTP.websocket("/ws")

        assert {:error, %WebSockex.RequestError{code: 501}} =
                 WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        request =
          {
            String.to_charlist(TestServer.HTTP.url("/ws")),
            [
              {~c"connection", ~c"Upgrade"},
              {~c"upgrade", ~c"websocket"},
              {~c"sec-websocket-version", ~c"13"},
              {~c"sec-websocket-key",
               :crypto.strong_rand_bytes(16) |> Base.encode64() |> String.to_charlist()}
            ]
          }

        # Test the body response
        TestServer.HTTP.websocket("/ws")

        assert {:ok, {{_, 501, _}, _headers, body}} = :httpc.request(:get, request, [], [])
        assert to_string(body) == "WebSocket is not supported with httpd!"
      end
    end

    describe "websocket_handle/2" do
      # No tests for `websocket_handle/2` as websocket endpoints always return
      # a 501 response, so no websocket is ever initialized to be handled.
    end

    describe "websocket_send/2" do
      # No tests for `websocket_send/2` as websocket endpoints always return a
      # 501 response, so no websocket is ever initialized to be handled.
    end
  else
    describe "websocket/3" do
      test "when instance not running" do
        instance = TestServer.HTTP.start!()
        :ok = TestServer.HTTP.stop()

        assert_raise RuntimeError,
                     ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is not running/,
                     fn ->
                       TestServer.HTTP.websocket(instance, path: "/ws")
                     end
      end

      test "with multiple instances" do
        TestServer.HTTP.start!()
        TestServer.HTTP.start!()

        assert_raise RuntimeError,
                     ~r/Multiple instances running, please pass instance to `TestServer\.HTTP\.websocket\/1`/,
                     fn ->
                       TestServer.HTTP.websocket("/ws")
                     end
      end

      test "with invalid options" do
        assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
          TestServer.HTTP.websocket(to: :invalid)
        end

        assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
          TestServer.HTTP.websocket(match: :invalid)
        end
      end

      test "with path argument" do
        TestServer.HTTP.websocket("/ws")

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
        assert WebSocketClient.close(client) == :ok
      end

      test "with instance and path argument" do
        instance = TestServer.HTTP.start!()
        TestServer.HTTP.websocket(instance, "/ws")

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url(instance, "/ws"))
        assert WebSocketClient.close(client) == :ok
      end

      test "with `:to` function returning set conn" do
        websocket =
          TestServer.HTTP.websocket("/ws",
            to: fn conn ->
              Plug.Conn.resp(conn, 403, "Forbidden")
            end
          )

        assert {:error, %WebSockex.RequestError{code: 403}} =
                 WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        # Ensure that the websocket was not accepted
        assert_raise RuntimeError,
                     ~r/cannot send to the websocket, because no client has connected to it/,
                     fn ->
                       TestServer.HTTP.websocket_send(websocket)
                     end
      end

      test "with `:to` function returning unset conn" do
        TestServer.HTTP.websocket("/ws",
          to: fn conn ->
            assert Plug.Conn.get_req_header(conn, "upgrade") == ["websocket"]

            conn
          end
        )

        assert {:ok, _client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
      end
    end

    describe "websocket_handle/2" do
      test "when instance not running" do
        instance = TestServer.HTTP.start!()
        websocket = TestServer.HTTP.websocket("/ws")
        :ok = TestServer.HTTP.stop(instance)

        assert_raise RuntimeError,
                     ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is not running/,
                     fn ->
                       TestServer.HTTP.websocket_handle(websocket)
                     end
      end

      test "with invalid options" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
          TestServer.HTTP.websocket_handle(websocket, to: :invalid)
        end

        assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
          TestServer.HTTP.websocket_handle(websocket, match: :invalid)
        end

        TestServer.HTTP.stop()
      end

      test "when no message received" do
        defmodule WebSocketHandleNoMessageTest do
          use ExUnit.Case

          test "fails" do
            websocket = TestServer.HTTP.websocket("/ws")

            assert {:ok, _client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

            TestServer.HTTP.websocket_handle(websocket)
          end
        end

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "did not receive a frame for these websocket handlers before the test ended:"
      end

      test "when receiving unexpected frame" do
        defmodule WebSocketHandleUnexpectedFrameTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)
            TestServer.HTTP.websocket("/ws")

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert {:ok, message} = WebSocketClient.send_message(client, "ping")

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketHandleUnexpectedFrameTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "received an unexpected WebSocket frame"
        assert io =~ "No active websocket handlers."
        refute io =~ "The following websocket handlers have been processed:"
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "when receiving unexpected frame before all handlers are processed" do
        defmodule WebSocketHandleUnexpectedBeforeProcessedTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)
            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket,
              match: fn _frame, _state -> false end
            )

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert {:ok, message} = WebSocketClient.send_message(client, "ping")

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketHandleUnexpectedBeforeProcessedTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "received an unexpected WebSocket frame"
        refute io =~ "No active websocket handlers."
        refute io =~ "The following websocket handlers have been processed:"
        assert io =~ "Active websocket handlers:"
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "when receiving unexpected frame after all handlers are processed" do
        defmodule WebSocketHandleUnexpectedAfterProcessedTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)
            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket)

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert WebSocketClient.send_message(client, "ping") == {:ok, "ping"}
            assert {:ok, message} = WebSocketClient.send_message(client, "ping")

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketHandleUnexpectedAfterProcessedTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "received an unexpected WebSocket frame"
        assert io =~ "No active websocket handlers."
        assert io =~ "The following websocket handlers have been processed:"
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "when receiving control frame" do
        websocket = TestServer.HTTP.websocket("/ws")

        TestServer.HTTP.websocket_handle(websocket)

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
        assert WebSocketClient.send_frame(client, {:pong, "client-pong"}) == :ok
        assert WebSocketClient.ping(client, "probe") == {:ok, {:pong, "probe"}}
        assert WebSocketClient.send_message(client, "ping") == {:ok, "ping"}
      end

      test "when `:to` function raises exception" do
        defmodule WebSocketHandleToFunctionRaiseTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)
            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket,
              to: fn _frame, _state -> raise "boom" end
            )

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert {:ok, message} = WebSocketClient.send_message(client, "ping")

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketHandleToFunctionRaiseTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "(RuntimeError) boom"
        assert io =~ "anonymous fn/2 in TestServer.HTTPTest.WebSocketHandleToFunctionRaiseTest"
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "when `:to` function returns invalid response" do
        defmodule WebSocketHandleToFunctionInvalidResponseTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)
            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket,
              to: fn _frame, _state -> :invalid end
            )

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert {:ok, message} = WebSocketClient.send_message(client, "ping")

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketHandleToFunctionInvalidResponseTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "with `:to` function" do
        websocket = TestServer.HTTP.websocket("/ws")

        TestServer.HTTP.websocket_handle(websocket,
          to: fn {:text, _any}, state -> {:reply, {:text, "function called"}, state} end
        )

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
        assert WebSocketClient.send_message(client, "ping") == {:ok, "function called"}
      end

      test "when `:match` function raises exception" do
        defmodule WebSocketHandleMatchFunctionRaiseTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)

            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket,
              match: fn _frame, _state -> raise "boom" end
            )

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert {:ok, message} = WebSocketClient.send_message(client, "ping")

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketHandleMatchFunctionRaiseTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "(RuntimeError) boom"
        assert io =~ "anonymous fn/2 in TestServer.HTTPTest.WebSocketHandleMatchFunctionRaiseTest"
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "with `:match` function" do
        websocket = TestServer.HTTP.websocket("/ws")

        TestServer.HTTP.websocket_handle(websocket,
          match: fn {:text, message}, _state -> message == "first" end,
          to: fn {:text, _any}, state -> {:reply, {:text, "pong"}, state} end
        )

        TestServer.HTTP.websocket_handle(websocket,
          match: fn {:text, message}, _state -> message == "second" end
        )

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
        assert WebSocketClient.send_message(client, "second") == {:ok, "second"}
        assert WebSocketClient.send_message(client, "first") == {:ok, "pong"}
      end
    end

    describe "websocket_send/2" do
      test "when instance not running" do
        instance = TestServer.HTTP.start!()
        websocket = TestServer.HTTP.websocket("/ws")
        :ok = TestServer.HTTP.stop(instance)

        assert_raise RuntimeError,
                     ~r/TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> is not running/,
                     fn ->
                       TestServer.HTTP.websocket_send(websocket)
                     end
      end

      test "with invalid options" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert {:ok, _client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
          TestServer.HTTP.websocket_send(websocket, to: :invalid)
        end
      end

      test "when client has not connected" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert_raise RuntimeError,
                     ~r/cannot send to the websocket, because no client has connected to it/,
                     fn ->
                       TestServer.HTTP.websocket_send(websocket)
                     end

        TestServer.HTTP.stop()
      end

      test "when connection doesn't exist" do
        instance = TestServer.HTTP.start!()

        assert_raise RuntimeError,
                     ~r/cannot send to the websocket, because the websocket does not exist/,
                     fn ->
                       TestServer.HTTP.websocket_send({instance, make_ref()})
                     end
      end

      test "when client has disconnected" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
        assert monitor = Process.monitor(client)
        assert WebSocketClient.close(client) == :ok
        assert_receive {:DOWN, ^monitor, :process, ^client, _reason}

        assert_raise RuntimeError,
                     ~r/cannot send to the websocket, because client has disconnected/,
                     fn ->
                       TestServer.HTTP.websocket_send(websocket)
                     end
      end

      test "sends" do
        websocket = TestServer.HTTP.websocket("/ws")
        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        TestServer.HTTP.websocket_send(websocket)

        assert WebSocketClient.receive_message(client) == {:ok, "ping"}
      end

      test "when `:to` function raises exception" do
        defmodule WebSocketSendToFunctionRaiseTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)

            websocket = TestServer.HTTP.websocket("/ws")

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

            TestServer.HTTP.websocket_send(websocket, to: fn _state -> raise "boom" end)

            assert {:ok, message} = WebSocketClient.receive_message(client)

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketSendToFunctionRaiseTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "(RuntimeError) boom"
        assert io =~ "anonymous fn/1 in TestServer.HTTPTest.WebSocketSendToFunctionRaiseTest"
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "when `:to` function returns an invalid response" do
        defmodule WebSocketSendToInvalidResponseTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)
            websocket = TestServer.HTTP.websocket("/ws")

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

            TestServer.HTTP.websocket_send(websocket, to: fn _state -> :invalid end)

            assert {:ok, message} = WebSocketClient.receive_message(client)

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketSendToInvalidResponseTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "(RuntimeError) Invalid callback response, got: :invalid."
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "when `:to` function returns `{:reply, frame, state}` with invalid frame" do
        defmodule WebSocketSendToInvalidFrameTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(suppress_warning: true)
            websocket = TestServer.HTTP.websocket("/ws")

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

            TestServer.HTTP.websocket_send(websocket,
              to: fn state -> {:reply, :invalid, state} end
            )

            assert {:ok, message} = WebSocketClient.receive_message(client)

            send(__MODULE__, {:message, message})
          end
        end

        Process.register(self(), WebSocketSendToInvalidFrameTest)

        assert io = capture_io(fn -> ExUnit.run() end)
        assert io =~ "(RuntimeError) Invalid callback response, got: {:reply, :invalid, %{}}"
        assert_receive {:message, message}
        assert_io_websocket_message(io, message)
      end

      test "when `:to` function returns `{:reply, {:text, text}, state}`" do
        websocket = TestServer.HTTP.websocket("/ws")
        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        TestServer.HTTP.websocket_send(websocket,
          to: fn state ->
            {:reply, {:text, "pong"}, state}
          end
        )

        assert WebSocketClient.receive_message(client) == {:ok, "pong"}
      end

      test "when `:to` function returns `{:reply, {:binary, binary}, state}`" do
        websocket = TestServer.HTTP.websocket("/ws")
        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        TestServer.HTTP.websocket_send(websocket,
          to: fn state ->
            {:reply, {:binary, "pong"}, state}
          end
        )

        assert WebSocketClient.receive_message(client) == {:ok, {:binary, "pong"}}
      end

      test "when `:to` function returns `{:ok, state}`" do
        websocket = TestServer.HTTP.websocket("/ws")
        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        TestServer.HTTP.websocket_send(websocket,
          to: fn state -> {:ok, Map.put(state, :a, 1)} end
        )

        TestServer.HTTP.websocket_send(websocket,
          to: fn state -> {:reply, {:text, inspect(state)}, state} end
        )

        assert WebSocketClient.receive_message(client) == {:ok, inspect(%{a: 1})}
      end
    end

    defp assert_io_websocket_message(io, message) do
      assert normalize_exception_message(io) =~ normalize_exception_message(message)
    end

    defp normalize_exception_message(message) do
      message
      |> String.replace(~r/\e\[[0-9;]*[mK]/, "")
      |> String.replace(~r/\n\s*stacktrace:\s*\n/, "\n")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end
  end

  def http1_request(url, options \\ []) do
    url = String.to_charlist(url)

    options
    |> Keyword.get(:method, :get)
    |> case do
      :post -> {:post, {url, [], ~c"plain/text", ~c"OK"}}
      :get -> {:get, {url, []}}
    end
    |> then(fn {method, request} ->
      httpc_http_options = Keyword.get(options, :http_options, [])

      :httpc.request(method, request, httpc_http_options, [])
    end)
    |> case do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, IO.iodata_to_binary(body)}
      {:ok, {{_, _, _}, _headers, body}} -> {:error, IO.iodata_to_binary(body)}
      {:error, error} -> {:error, error}
    end
  end

  # `:httpd` has no HTTP/2 support
  unless System.get_env("HTTP_SERVER") == "Httpd" do
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

  defmodule WebSocketClient do
    use WebSockex

    def start_link(url) do
      WebSockex.start_link(url, __MODULE__, self())
    end

    def handle_connect(_conn, caller) do
      {:ok, caller}
    end

    def handle_frame({:text, message}, caller) do
      send(caller, {:websocket, self(), message})

      {:ok, caller}
    end

    def handle_frame({:binary, message}, caller) do
      send(caller, {:websocket, self(), {:binary, message}})

      {:ok, caller}
    end

    def handle_cast(:close, state) do
      {:close, {1_000, "Bye"}, state}
    end

    def handle_pong(frame, caller) do
      send(caller, {:frame, self(), frame})

      {:ok, caller}
    end

    def send_frame(client, frame) do
      WebSockex.send_frame(client, frame)
    end

    def ping(client, payload) do
      :ok = send_frame(client, {:ping, payload})

      receive do
        {:frame, ^client, frame} -> {:ok, frame}
      after
        100 -> {:error, :timeout}
      end
    end

    def send_message(client, message) do
      send_frame(client, {:text, message})

      receive_message(client)
    end

    def receive_message(client) do
      receive do
        {:websocket, ^client, message} -> {:ok, message}
      after
        100 -> {:error, :timeout}
      end
    end

    def close(client) do
      WebSockex.cast(client, :close)
    end
  end
end
