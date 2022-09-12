defmodule TestServerTest do
  use ExUnit.Case
  doctest TestServer

  import ExUnit.CaptureIO

  describe "start/1" do
    test "with invalid port" do
      assert_raise RuntimeError, ~r/Invalid port, got: :invalid/, fn ->
        TestServer.start(port: :invalid)
      end
    end

    test "with invalid scheme" do
      assert_raise RuntimeError, ~r/Invalid scheme, got: :invalid/, fn ->
        TestServer.start(scheme: :invalid)
      end
    end

    test "starts with multiple ports" do
      {:ok, instance_1} = TestServer.start()
      {:ok, instance_2} = TestServer.start()

      refute instance_1 == instance_2

      options_1 = TestServer.Instance.get_options(instance_1)
      options_2 = TestServer.Instance.get_options(instance_2)

      refute options_1[:port] == options_2[:port]
    end

    test "starts with self-signed SSL" do
      {:ok, instance} = TestServer.start(scheme: :https)

      options = TestServer.Instance.get_options(instance)

      assert %X509.Test.Suite{} = options[:x509_suite]
      assert options[:cowboy_options][:key]

      httpc_opts = fn cacerts ->
        [
          ssl: [
            verify: :verify_peer,
            depth: 99,
            cacerts: cacerts,
            verify_fun: {&:ssl_verify_hostname.verify_fun/3, check_hostname: 'localhost'},
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
      end

      valid_cacerts = TestServer.x509_suite().cacerts
      invalid_cacerts = X509.Test.Suite.new().cacerts

      assert {:error, {:failed_connect, _}} =
               request(TestServer.url("/"), httpc_opts: httpc_opts.(invalid_cacerts))

      assert :ok = TestServer.add("/")
      assert {:ok, _} = request(TestServer.url("/"), httpc_opts: httpc_opts.(valid_cacerts))
    end
  end

  describe "stop/1" do
    test "when not running" do
      assert_raise RuntimeError, "No current TestServer.Instance is not running", fn ->
        TestServer.stop()
      end

      assert_raise RuntimeError, ~r/The TestServer.Instance \#PID\<.*\> is not running/, fn ->
        {:ok, instance} = TestServer.start()

        assert :ok = TestServer.stop()

        TestServer.stop(instance)
      end
    end

    test "stops" do
      assert {:ok, pid} = TestServer.start()
      url = TestServer.url("/")

      assert :ok = TestServer.stop()
      refute Process.alive?(pid)

      assert {:error, {:failed_connect, _}} = request(url)
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.start()
      {:ok, _instance_2} = TestServer.start()

      assert_raise RuntimeError,
                   ~r/Multiple TestServer\.Instance's running, please pass instance to `TestServer\.stop\/0`/,
                   fn ->
                     TestServer.stop()
                   end

      assert :ok = TestServer.stop(instance_1)
      assert :ok = TestServer.stop()
    end
  end

  describe "url/3" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.Instance is not running", fn ->
        TestServer.url()
      end

      assert_raise RuntimeError, ~r/The TestServer.Instance \#PID\<.*\> is not running/, fn ->
        {:ok, instance} = TestServer.start()

        assert :ok = TestServer.stop()

        TestServer.url(instance)
      end
    end

    test "invalid `:host`" do
      TestServer.start()

      assert_raise RuntimeError, ~r/Invalid host, got: :invalid/, fn ->
        TestServer.url("/", host: :invalid)
      end
    end

    test "produces routes" do
      TestServer.start()

      assert TestServer.url("/") =~ ~r/^http\:\/\/localhost\:[0-9]+\/$/
      refute TestServer.url("/") == TestServer.url("/path")
      refute TestServer.url("/") == TestServer.url("/", host: "bad-host")
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.start()
      {:ok, instance_2} = TestServer.start()

      assert_raise RuntimeError,
                   ~r/Multiple TestServer\.Instance's running, please pass instance to `TestServer\.url\/2`/,
                   fn ->
                     TestServer.url()
                   end

      refute TestServer.url(instance_1) == TestServer.url(instance_2)
    end
  end

  describe "add/3" do
    test "when instance not running" do
      assert_raise RuntimeError, ~r/The TestServer.Instance \#PID\<.*\> is not running/, fn ->
        {:ok, instance} = TestServer.start()

        assert :ok = TestServer.stop()

        TestServer.add(instance, "/")
      end
    end

    test "invalid options" do
      assert_raise BadFunctionError, ~r/expected a function, got: :invalid/, fn ->
        TestServer.add("/", match: :invalid)
      end

      assert_raise BadFunctionError, ~r/expected a function, got: "not a plug"/, fn ->
        TestServer.add("/", to: "not a plug")
      end
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.start()
      {:ok, _instance_2} = TestServer.start()

      assert_raise RuntimeError,
                   ~r/Multiple TestServer\.Instance's running, please pass instance to `TestServer\.add\/2`/,
                   fn ->
                     TestServer.add("/")
                   end

      assert :ok = TestServer.add(instance_1, "/")

      TestServer.stop(instance_1)
    end

    test "with mismatching URI" do
      defmodule MismatchingURITest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.start(suppress_warning: true)
          assert :ok = TestServer.add("/")
          assert {:error, _} = unquote(__MODULE__).request(TestServer.url("/path"))
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "Unexpected GET request received at /path."
    end

    test "with mismatching method" do
      defmodule MismatchingMethodTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.start(suppress_warning: true)

          assert :ok = TestServer.add("/", via: :post)
          assert {:error, _} = unquote(__MODULE__).request(TestServer.url("/"))
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "Unexpected GET request received at /."
    end

    test "with too many requests" do
      defmodule TooManyRequestsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.start(suppress_warning: true)
          assert :ok = TestServer.add("/")

          assert {:ok, _} = unquote(__MODULE__).request(TestServer.url("/"))
          assert {:error, _} = unquote(__MODULE__).request(TestServer.url("/"))
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~ "Unexpected GET request received at /."
    end

    test "with no requests" do
      defmodule NoRequestTest do
        use ExUnit.Case

        test "fails" do
          assert :ok = TestServer.add("/")
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "The test ended before the following TestServer.Instance route(s) received a request"
    end

    test "with callback plug" do
      defmodule ToPlug do
        def init(opts), do: opts

        def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, to_string(__MODULE__))
      end

      assert :ok = TestServer.add("/", to: ToPlug)
      assert request(TestServer.url("/")) == {:ok, to_string(ToPlug)}
    end

    test "with callback function raising exception" do
      defmodule ToFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.start(suppress_warning: true)

          assert :ok = TestServer.add("/", to: fn _conn -> raise "boom" end)
          assert {:error, _} = unquote(__MODULE__).request(TestServer.url("/"))
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServerTest.ToFunctionRaiseTest"
    end

    test "with callback function halts" do
      defmodule ToFunctionHaltsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.start(suppress_warning: true)

          assert :ok = TestServer.add("/", to: fn conn -> Plug.Conn.halt(conn) end)
          assert {:error, _} = unquote(__MODULE__).request(TestServer.url("/"))
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "Do not halt a connection. All requests are has to be processed."
    end

    test "with callback function" do
      assert :ok =
               TestServer.add("/",
                 to: fn conn -> Plug.Conn.send_resp(conn, 200, "function called") end
               )

      assert request(TestServer.url("/")) == {:ok, "function called"}
    end

    test "with match function" do
      assert :ok =
               TestServer.add("/",
                 match: fn
                   %{params: %{"a" => "1"}} = _conn -> true
                   _conn -> false
                 end
               )

      assert {:ok, _} = request(TestServer.url("/ignore") <> "?a=1")
    end

    test "with :via method" do
      assert :ok = TestServer.add("/", via: :get)
      assert :ok = TestServer.add("/", via: :post)
      assert {:ok, _} = request(TestServer.url("/"))
      assert {:ok, _} = request(TestServer.url("/"), method: :post)
    end
  end

  describe "plug/2" do
    test "with plug function" do
      assert :ok =
               TestServer.plug(fn conn ->
                 %{conn | params: %{"plug" => "anonymous function"}}
               end)

      assert :ok = TestServer.add("/", to: &Plug.Conn.send_resp(&1, 200, &1.params["plug"]))

      assert {:ok, "anonymous function"} = request(TestServer.url("/"))
    end

    test "with plug module" do
      defmodule ModulePlug do
        def init(opts), do: opts

        def call(conn, _opts), do: %{conn | params: %{"plug" => to_string(__MODULE__)}}
      end

      assert :ok = TestServer.plug(ModulePlug)
      assert :ok = TestServer.add("/", to: &Plug.Conn.send_resp(&1, 200, &1.params["plug"]))
      assert request(TestServer.url("/")) == {:ok, to_string(ModulePlug)}
    end

    test "when plug errors" do
      defmodule PlugFunctionRaiseTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.start(suppress_warning: true)

          assert :ok = TestServer.plug(fn _conn -> raise "boom" end)
          assert {:error, _} = unquote(__MODULE__).request(TestServer.url("/"))
        end
      end

      assert io = capture_io(fn -> ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServerTest.PlugFunctionRaiseTest"
    end

    test "when plug function halts" do
      defmodule PlugFunctionHaltsTest do
        use ExUnit.Case

        test "fails" do
          {:ok, _instance} = TestServer.start(suppress_warning: true)

          assert :ok = TestServer.plug(fn conn -> Plug.Conn.halt(conn) end)
          assert :ok = TestServer.add("/")
          assert {:error, _} = unquote(__MODULE__).request(TestServer.url("/"))
        end
      end

      assert capture_io(fn -> ExUnit.run() end) =~
               "Do not halt a connection. All requests are has to be processed."
    end
  end

  describe "x509_suite/0" do
    test "when instance not running" do
      assert_raise RuntimeError, "No current TestServer.Instance is not running", fn ->
        TestServer.x509_suite()
      end

      assert_raise RuntimeError, ~r/The TestServer.Instance \#PID\<.*\> is not running/, fn ->
        {:ok, instance} = TestServer.start()

        assert :ok = TestServer.stop()

        TestServer.x509_suite(instance)
      end
    end

    test "when instance not running in http" do
      TestServer.start()

      assert_raise RuntimeError,
                   "The TestServer.Instance is not running with `[scheme: :https]` option",
                   fn ->
                     TestServer.x509_suite()
                   end
    end

    test "when instance runs with custom SSL" do
      suite = X509.Test.Suite.new()

      cowboy_options = [
        key: {:RSAPrivateKey, X509.PrivateKey.to_der(suite.server_key)},
        cert: X509.Certificate.to_der(suite.valid),
        cacerts: suite.chain ++ suite.cacerts
      ]

      TestServer.start(scheme: :https, cowboy_options: cowboy_options)

      assert_raise RuntimeError, ~r/The TestServer.Instance is running with custom SSL/, fn ->
        TestServer.x509_suite()
      end
    end
  end

  def request(url, opts \\ []) do
    url = String.to_charlist(url)
    httpc_opts = Keyword.get(opts, :httpc_opts, [])

    opts
    |> Keyword.get(:method, :get)
    |> case do
      :post -> :httpc.request(:post, {url, [], 'plain/text', 'OK'}, httpc_opts, [])
      :get -> :httpc.request(:get, {url, []}, httpc_opts, [])
    end
    |> case do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, to_string(body)}
      {:ok, {{_, _, _}, _headers, body}} -> {:error, to_string(body)}
      {:error, error} -> {:error, error}
    end
  end
end
