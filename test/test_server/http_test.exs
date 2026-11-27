defmodule TestServer.HTTPTest do
  use ExUnit.Case
  doctest TestServer.HTTP

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias __MODULE__.{HTTPClient, WebSocketClient}

  describe "start/1" do
    test "with invalid options" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.HTTP.start(invalid: :option)
      end
    end

    test "with invalid `:port` option" do
      assert_raise ArgumentError,
                   ~r/expected :port to be an integer from 0 to 65535, got: :invalid/,
                   fn ->
                     TestServer.HTTP.start(port: :invalid)
                   end
    end

    test "with invalid `:ip` option" do
      assert_raise ArgumentError,
                   ~r/expected :ip to be an IP tuple, :any, or :loopback, got: :invalid/,
                   fn ->
                     TestServer.HTTP.start(ip: :invalid)
                   end
    end

    test "with invalid `:scheme` option" do
      assert_raise ArgumentError,
                   ~r/expected :scheme to be :http or :https, got: :invalid/,
                   fn ->
                     TestServer.HTTP.start(scheme: :invalid)
                   end
    end

    test "with start error" do
      instance = TestServer.HTTP.start!()
      port = instance |> TestServer.HTTP.Instance.options() |> Keyword.fetch!(:port)

      log =
        capture_log(fn ->
          assert {:error, error} = TestServer.HTTP.start(port: port)
          assert_http_eaddrinuse_error(error)
        end)

      case Application.fetch_env!(:test_server, :http_server) do
        {TestServer.HTTP.Server.Bandit, []} -> assert log =~ "already in use"
        {TestServer.HTTP.Server.Plug.Cowboy, []} -> assert log =~ "already in use"
        {TestServer.HTTP.Server.Httpd, []} -> assert log == ""
      end
    end

    defp assert_http_eaddrinuse_error(error) do
      {mod, []} = Application.fetch_env!(:test_server, :http_server)

      assert_http_eaddrinuse_error(mod, error)
    end

    defp assert_http_eaddrinuse_error(TestServer.HTTP.Server.Bandit, error) do
      assert error == {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}
    end

    defp assert_http_eaddrinuse_error(TestServer.HTTP.Server.Plug.Cowboy, error) do
      assert error == :eaddrinuse
    end

    defp assert_http_eaddrinuse_error(TestServer.HTTP.Server.Httpd, error) do
      assert {:already_started, _pid} = error
    end

    test "with multiple instances" do
      {:ok, instance_1} = TestServer.HTTP.start()
      {:ok, instance_2} = TestServer.HTTP.start()

      refute instance_1 == instance_2

      options_1 = TestServer.HTTP.Instance.options(instance_1)
      options_2 = TestServer.HTTP.Instance.options(instance_2)

      refute options_1[:port] == options_2[:port]
    end

    test "with `ipfamily: :inet6` option" do
      instance = TestServer.HTTP.start!(ipfamily: :inet6)
      ip = instance |> TestServer.HTTP.Instance.options() |> Keyword.fetch!(:ip)

      TestServer.HTTP.handle(
        to: fn conn ->
          assert %{address: address} = Plug.Conn.get_sock_data(conn)
          assert address == {0, 0, 0, 0, 0, 0, 0, 1}
          assert conn.remote_ip == {0, 0, 0, 0, 0, 0, 0, 1}

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert ip == {0, 0, 0, 0, 0, 0, 0, 1}
      assert {:ok, _} = HTTPClient.fetch(TestServer.HTTP.url(), ipfamily: :inet6)
    end

    test "with `:ip` option" do
      instance = TestServer.HTTP.start!(ip: {0, 0, 0, 0})
      ip = instance |> TestServer.HTTP.Instance.options() |> Keyword.fetch!(:ip)

      TestServer.HTTP.handle(
        to: fn conn ->
          assert %{address: address} = Plug.Conn.get_sock_data(conn)
          assert address == {127, 0, 0, 1}
          assert conn.remote_ip == {127, 0, 0, 1}

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      assert ip == {0, 0, 0, 0}
      assert {:ok, _} = HTTPClient.fetch(TestServer.HTTP.url())
    end

    test "with `scheme: :https` option" do
      instance = TestServer.HTTP.start!(scheme: :https)
      options = TestServer.HTTP.Instance.options(instance)

      assert Keyword.has_key?(options, :cacerts)

      valid_cacerts = TestServer.HTTP.cacerts()
      %{cacerts: invalid_cacerts} = X509.Test.Suite.new()

      assert {:error, {:failed_connect, _}} =
               HTTPClient.fetch(TestServer.HTTP.url(),
                 ssl: tls_options(invalid_cacerts)
               )

      TestServer.HTTP.handle()

      assert {:ok, _} =
               HTTPClient.fetch(TestServer.HTTP.url(),
                 ssl: tls_options(valid_cacerts)
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
               HTTPClient.fetch(TestServer.HTTP.url(), ssl: tls_options(cacerts))
    end

    test "with invalid `:http_server` option" do
      assert_raise ArgumentError,
                   ~r/expected :http_server to be a \{module, options\} tuple, got: :invalid/,
                   fn ->
                     TestServer.HTTP.start(http_server: :invalid)
                   end
    end

    test "when test ends" do
      defmodule StartEndTest do
        use ExUnit.Case

        test "succeeds" do
          instance = TestServer.HTTP.start!()
          options = TestServer.HTTP.Instance.options(instance)
          port = Keyword.fetch!(options, :port)
          server_pid = Keyword.fetch!(options, :server)

          send(__MODULE__, {:server, server_pid, port})

          assert {:error, :eaddrinuse} = :gen_tcp.listen(port, [])
        end
      end

      Process.register(self(), StartEndTest)

      assert capture_io(fn -> assert %{failures: 0} = ExUnit.run() end)
      assert_receive {:server, server_pid, port}
      assert monitor = Process.monitor(server_pid)
      assert_receive {:DOWN, ^monitor, :process, ^server_pid, _reason}
      assert {:ok, socket} = :gen_tcp.listen(port, [])
      assert :ok = :gen_tcp.close(socket)
    end

    test "when instance shuts down" do
      defmodule StartInstanceCrashTest do
        use ExUnit.Case

        test "fails" do
          {TestServer.HTTP, instance_pid} = instance = TestServer.HTTP.start!()

          server_pid =
            instance
            |> TestServer.HTTP.Instance.options()
            |> Keyword.fetch!(:server)

          monitor = Process.monitor(server_pid)

          Process.exit(instance_pid, :shutdown)

          assert_receive {:DOWN, ^monitor, :process, ^server_pid, _reason}
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)

      assert io =~
               ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it exited with reason:/

      assert io =~ "     shutdown"
    end

    test "when server crashes" do
      defmodule StartServerCrashTest do
        use ExUnit.Case

        test "fails" do
          {TestServer.HTTP, instance_pid} = instance = TestServer.HTTP.start!()

          options = TestServer.HTTP.Instance.options(instance)
          server_pid = Keyword.fetch!(options, :server)
          port = Keyword.fetch!(options, :port)

          monitor = Process.monitor(instance_pid)
          true = Process.exit(server_pid, :kill)

          send(__MODULE__, {:server, server_pid, port})

          assert_receive {:DOWN, ^monitor, :process, ^instance_pid, _reason}
        end
      end

      Process.register(self(), StartServerCrashTest)

      {{server_pid, port}, log} =
        with_log(fn ->
          assert io =
                   capture_io(fn ->
                     assert %{failures: 1} = ExUnit.run()
                   end)

          assert io =~
                   ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it exited with reason:/

          assert io =~ "     shutdown: :killed"

          assert_receive {:server, server_pid, port}

          # Inets crash crashes the supervisor which can leak to other tests
          wait_till_httpd_process_removed(server_pid)

          {server_pid, port}
        end)

      case Application.fetch_env!(:test_server, :http_server) do
        {TestServer.HTTP.Server.Bandit, []} ->
          assert log =~ ~r/GenServer \#PID\<[0-9.]+\> terminating/

        {TestServer.HTTP.Server.Plug.Cowboy, []} ->
          assert log =~ ~r/GenServer \#PID\<[0-9.]+\> terminating/

        {TestServer.HTTP.Server.Httpd, []} ->
          assert log =~ ~r/GenServer :httpd__127_0_0_1__#{port}default terminating/
          assert log =~ inspect(server_pid)
      end
    end
  end

  defp wait_till_httpd_process_removed(server_pid, attempts \\ 10)

  defp wait_till_httpd_process_removed(server_pid, 0) do
    flunk("expected httpd process #{inspect(server_pid)} to be removed")
  end

  defp wait_till_httpd_process_removed(server_pid, attempts) do
    :inets.services()
    |> Enum.filter(fn
      {:httpd, ^server_pid} -> true
      {:httpd, :restarting} -> true
      _ -> false
    end)
    |> Enum.map(fn {:httpd, pid} -> pid end)
    |> case do
      [] ->
        :ok

      _processes ->
        :timer.sleep(10)
        wait_till_httpd_process_removed(server_pid, attempts - 1)
    end
  end

  describe "start!/1" do
    test "returns instance" do
      assert {TestServer.HTTP, instance_pid} = TestServer.HTTP.start!()
      assert is_pid(instance_pid)
    end

    for {ip, text, text_port} <- [
          {:any, "", " on port "},
          {:loopback, " on localhost", " on localhost:"},
          {{127, 0, 0, 1}, " on 127.0.0.1", " on 127.0.0.1:"},
          {{0, 0, 0, 0, 0, 0, 0, 1}, " on [::1]", " on [::1]:"}
        ] do
      test "when start fails with `ip: #{inspect(ip)}`" do
        {http_server, []} = Application.fetch_env!(:test_server, :http_server)

        invalid_options =
          case http_server do
            TestServer.HTTP.Server.Bandit -> [invalid: 1]
            TestServer.HTTP.Server.Plug.Cowboy -> [invalid: 1]
            TestServer.HTTP.Server.Httpd -> [server_name: :invalid]
          end

        http_server = {http_server, invalid_options}

        capture_log(fn ->
          error =
            assert_raise RuntimeError, fn ->
              TestServer.HTTP.start!(ip: unquote(Macro.escape(ip)), http_server: http_server)
            end

          assert Exception.message(error) =~
                   "could not start TestServer.HTTP instance#{unquote(text)}:\n\n"
        end)
      end

      test "when start fails with `ip: #{inspect(ip)}` and `:port` set" do
        log =
          capture_log(fn ->
            instance = TestServer.HTTP.start!(ip: unquote(Macro.escape(ip)))
            port = instance |> TestServer.HTTP.Instance.options() |> Keyword.fetch!(:port)

            error =
              assert_raise RuntimeError, fn ->
                TestServer.HTTP.start!(ip: unquote(Macro.escape(ip)), port: port)
              end

            assert Exception.message(error) =~
                     "could not start TestServer.HTTP instance#{unquote(text_port)}#{port}:"
          end)

        case Application.fetch_env!(:test_server, :http_server) do
          {TestServer.HTTP.Server.Bandit, []} -> assert log =~ "already in use"
          {TestServer.HTTP.Server.Plug.Cowboy, []} -> assert log =~ "already in use"
          {TestServer.HTTP.Server.Httpd, []} -> assert log == ""
        end
      end
    end
  end

  describe "stop/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "expected TestServer.HTTP.Instance to be running", fn ->
        TestServer.HTTP.stop()
      end

      assert_raise RuntimeError,
                   ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it was stopped at:/,
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
                   ~r/expected exactly one instance to be running, but got multiple instances; pass the instance to TestServer\.HTTP\.stop\/1/,
                   fn -> TestServer.HTTP.stop() end

      assert TestServer.HTTP.stop(instance_1) == :ok
      assert TestServer.HTTP.stop() == :ok
    end

    test "stops" do
      {TestServer.HTTP, instance_pid} = TestServer.HTTP.start!()
      url = TestServer.HTTP.url()

      assert TestServer.HTTP.stop() == :ok
      refute Process.alive?(instance_pid)
      assert {:error, {:failed_connect, _}} = HTTPClient.fetch(url)
    end
  end

  describe "url/3" do
    test "when instance not running" do
      assert_raise RuntimeError, "expected TestServer.HTTP.Instance to be running", fn ->
        TestServer.HTTP.url()
      end

      assert_raise RuntimeError,
                   ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it was stopped at:/,
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
                   ~r/expected exactly one instance to be running, but got multiple instances; pass the instance to TestServer\.HTTP\.url\/3/,
                   fn -> TestServer.HTTP.url() end

      refute TestServer.HTTP.url(instance_1) == TestServer.HTTP.url(instance_2)
    end

    test "with invalid options" do
      TestServer.HTTP.start!()

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.HTTP.url(ip: {127, 0, 0, 2})
      end
    end

    test "returns" do
      TestServer.HTTP.start!()

      assert TestServer.HTTP.url() =~ ~r/^http\:\/\/localhost\:[0-9]+$/
      assert TestServer.HTTP.url("/path") =~ "/path"
      assert TestServer.HTTP.url(host: "example.test") =~ ~r/^http\:\/\/example.test\:[0-9]+$/
    end

    test "with invalid `:host` option" do
      TestServer.HTTP.start!()

      assert_raise ArgumentError,
                   ~r/expected :host to be a binary, got: :invalid/,
                   fn ->
                     TestServer.HTTP.url(host: :invalid)
                   end
    end

    test "with `:host` option" do
      TestServer.HTTP.start!()

      TestServer.HTTP.handle(
        to: fn conn ->
          assert conn.remote_ip == {127, 0, 0, 1}
          assert conn.host == "example.test"

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      url = TestServer.HTTP.url(host: "example.test")

      assert %{host: "example.test"} = URI.parse(url)
      assert :inet.getaddr(~c"example.test", :inet) == {:ok, {127, 0, 0, 1}}
      assert :inet.getaddr(~c"example.test", :inet6) == {:error, :nxdomain}
      assert {:ok, _} = HTTPClient.fetch(url)
    end

    private_inet_ip = Application.compile_env(:test_server, :private_inet_ip)
    private_inet6_ip = Application.compile_env(:test_server, :private_inet6_ip)

    for {ip, bind_ip, host_ip, ipfamily} <- [
          {:loopback, {127, 0, 0, 1}, {127, 0, 0, 1}, :inet},
          {:any, {0, 0, 0, 0}, {127, 0, 0, 1}, :inet},
          {private_inet_ip, private_inet_ip, private_inet_ip, :inet},
          {private_inet6_ip, private_inet6_ip, private_inet6_ip, :inet6}
        ] do
      test "with `:host` option when started with `ip: #{inspect(ip)}` option when started with `ipfamily: #{inspect(ipfamily)}`" do
        options = [ip: unquote(Macro.escape(ip)), ipfamily: unquote(ipfamily)]
        instance = TestServer.HTTP.start!(options)
        ip = instance |> TestServer.HTTP.Instance.options() |> Keyword.fetch!(:ip)

        TestServer.HTTP.handle(
          to: fn conn ->
            assert %{address: address} = Plug.Conn.get_sock_data(conn)
            assert address == unquote(Macro.escape(host_ip))
            assert conn.remote_ip == unquote(Macro.escape(host_ip))
            assert conn.host == "example.test"

            Plug.Conn.resp(conn, 200, "OK")
          end
        )

        url = TestServer.HTTP.url(host: "example.test")

        assert ip == unquote(Macro.escape(bind_ip))
        assert %{host: host} = URI.parse(url)
        assert host = to_charlist(host)
        assert :inet.getaddr(host, unquote(ipfamily)) == {:ok, unquote(Macro.escape(host_ip))}
        assert {:ok, _} = HTTPClient.fetch(url, ipfamily: unquote(ipfamily))
      end
    end
  end

  describe "handle/3" do
    test "when instance not running" do
      assert_raise RuntimeError,
                   ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it was stopped at:/,
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
                   ~r/expected exactly one instance to be running, but got multiple instances; pass the instance to TestServer\.HTTP\.handle\/2/,
                   fn -> TestServer.HTTP.handle() end

      TestServer.HTTP.handle(instance_1)

      assert {:ok, _} = HTTPClient.fetch(TestServer.HTTP.url(instance_1))

      TestServer.HTTP.stop(instance_1)
    end

    test "with invalid options" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TestServer.HTTP.handle(invalid: :option)
      end
    end

    test "with invalid `:path` option" do
      assert_raise ArgumentError, ~r/expected :path to be a binary, got: :invalid/, fn ->
        TestServer.HTTP.handle(path: :invalid)
      end
    end

    test "with invalid `:method` option" do
      assert_raise ArgumentError, ~r/expected :method to be an atom or list, got: %{}/, fn ->
        TestServer.HTTP.handle(method: %{})
      end
    end

    test "with invalid `:match` option" do
      assert_raise ArgumentError,
                   ~r/expected :match to be a 1-arity function, got: :invalid/,
                   fn ->
                     TestServer.HTTP.handle(match: :invalid)
                   end

      assert_raise ArgumentError,
                   ~r/expected :match to be a 1-arity function, got: #Function/,
                   fn ->
                     TestServer.HTTP.handle(match: fn _conn, _opts -> true end)
                   end
    end

    test "with invalid `:to` option" do
      assert_raise ArgumentError,
                   "expected :to to be a 1-arity function, a Plug module, or a Plug module tuple, got: :invalid",
                   fn ->
                     TestServer.HTTP.handle(to: :invalid)
                   end

      assert_raise ArgumentError,
                   ~r/expected :to to be a 1-arity function, a Plug module, or a Plug module tuple, got: \#Function/,
                   fn ->
                     TestServer.HTTP.handle(to: fn conn, _options -> conn end)
                   end
    end

    test "when receiving no requests" do
      defmodule HandleNoRequestTest do
        use ExUnit.Case

        test "fails" do
          TestServer.HTTP.handle()
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)

      assert io =~
               ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to receive a request for these handlers before the test ended:/
    end

    test "when receiving unexpected request" do
      defmodule HandleUnexpectedRequestTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url("/?a=1"))
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "received an unexpected GET request at / with params:"
      assert io =~ "query_params: %{\"a\" => \"1\"}"
      assert io =~ "No active handlers."
      refute io =~ "The following handlers have been processed:"
    end

    test "when receiving unexpected request before all handlers are processed" do
      defmodule HandleUnexpectedRequestBeforeProcessedTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle(match: fn _conn -> false end)

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /."
      refute io =~ "No active handlers."
      refute io =~ "The following handlers have been processed:"
      assert io =~ "Active handlers:"

      assert io =~ "#1: any method at any path"
      assert io =~ ~r/test\/test_server\/http_test\.exs:\d+/
      assert io =~ "HandleUnexpectedRequestBeforeProcessedTest.\"test fails\"/1"
    end

    test "when receiving unexpected request after all handlers are processed" do
      defmodule HandleUnexpectedRequestAfterProcessedTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle()

          assert {:ok, _} = HTTPClient.fetch(TestServer.HTTP.url())
          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /."
      assert io =~ "No active handlers."
      assert io =~ "The following handlers have been processed:"
    end

    test "with path argument when path doesn't match" do
      defmodule HandlePathArgumentMismatchTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle("/path")

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url("/other-path"))
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /other-path."
    end

    test "with `:path` option when path doesn't match" do
      defmodule HandlePathOptionMismatchTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle(path: "/path", method: [:get, :post])

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url("/other-path"))
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /other-path."
      assert io =~ "Active handlers:"
      assert io =~ "#1: GET | POST at /path"
    end

    test "with `:method` option when method doesn't match" do
      defmodule HandleMethodMismatchTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle(method: :post)

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /."
      assert io =~ "#1: POST at any path"
    end

    test "with `method: []` option" do
      defmodule HandleMethodEmptyTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle(method: [])

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "received an unexpected GET request at /."
      assert io =~ "#1: no methods at any path"
    end

    test "with no path specified" do
      TestServer.HTTP.handle()

      assert {:ok, _} = HTTPClient.fetch(TestServer.HTTP.url("/path"))
    end

    test "with path argument" do
      TestServer.HTTP.handle("/1", to: &Plug.Conn.resp(&1, 200, "1"))
      TestServer.HTTP.handle("/2", to: &Plug.Conn.resp(&1, 200, "2"))

      assert HTTPClient.fetch(TestServer.HTTP.url("/2")) == {:ok, "2"}
      assert HTTPClient.fetch(TestServer.HTTP.url("/1")) == {:ok, "1"}
    end

    test "with instance and path argument" do
      instance = TestServer.HTTP.start!()
      TestServer.HTTP.handle(instance, "/path")

      assert {:ok, _} = HTTPClient.fetch(TestServer.HTTP.url(instance, "/path"))
    end

    test "with `:path` option" do
      TestServer.HTTP.handle(path: "/hi", to: &Plug.Conn.resp(&1, 200, "1"))
      TestServer.HTTP.handle(path: "/héllo-👋", to: &Plug.Conn.resp(&1, 200, "2"))

      assert HTTPClient.fetch(URI.encode(TestServer.HTTP.url("/héllo-👋"))) == {:ok, "2"}
      assert HTTPClient.fetch(TestServer.HTTP.url("/hi")) == {:ok, "1"}
    end

    test "with no `:method` option" do
      TestServer.HTTP.handle()

      assert {:ok, _} = HTTPClient.fetch(TestServer.HTTP.url(), method: :post)
    end

    test "with an empty `:method` option" do
      TestServer.HTTP.handle(
        method: [],
        to: fn _conn ->
          flunk("Handler should not be called")
        end
      )

      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, "second"))

      assert HTTPClient.fetch(TestServer.HTTP.url()) == {:ok, "second"}

      TestServer.HTTP.stop()
    end

    test "with `:method` option" do
      TestServer.HTTP.handle(method: :get, to: &Plug.Conn.resp(&1, 200, ":get"))
      TestServer.HTTP.handle(method: [:post, :get], to: &Plug.Conn.resp(&1, 200, "[:post, :get]"))
      TestServer.HTTP.handle(method: :post, to: &Plug.Conn.resp(&1, 200, ":post"))

      assert HTTPClient.fetch(TestServer.HTTP.url(), method: :post) == {:ok, "[:post, :get]"}
      assert HTTPClient.fetch(TestServer.HTTP.url()) == {:ok, ":get"}
      assert HTTPClient.fetch(TestServer.HTTP.url(), method: :post) == {:ok, ":post"}
    end

    test "with `:to` plug" do
      defmodule HandleToPlug do
        def init(options), do: options

        def call(conn, options), do: Plug.Conn.resp(conn, 200, inspect({__MODULE__, options}))
      end

      TestServer.HTTP.handle(to: HandleToPlug)
      TestServer.HTTP.handle(to: {HandleToPlug, [a: 1]})

      assert HTTPClient.fetch(TestServer.HTTP.url()) == {:ok, inspect({HandleToPlug, []})}
      assert HTTPClient.fetch(TestServer.HTTP.url()) == {:ok, inspect({HandleToPlug, [a: 1]})}
    end

    test "when `:to` function raises exception" do
      defmodule HandleToFunctionRaiseTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle(to: fn _conn -> raise "boom" end)

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.HTTPTest.HandleToFunctionRaiseTest"
    end

    test "with `:to` function returning invalid result" do
      defmodule HandleToFunctionInvalidResultTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle(to: fn _conn -> :invalid end)

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "expected a Plug.Conn struct, got: :invalid"
    end

    test "with `:to` function returning halted conn" do
      defmodule HandleToFunctionHaltedConnTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle(to: fn conn -> Plug.Conn.halt(conn) end)

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "cannot halt a connection because all requests must be processed"
    end

    test "with `:to` function" do
      TestServer.HTTP.handle(to: fn conn -> Plug.Conn.resp(conn, 200, "function called") end)

      assert HTTPClient.fetch(TestServer.HTTP.url()) == {:ok, "function called"}
    end

    test "when `:match` function raises exception" do
      defmodule HandleMatchFunctionRaiseTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.handle(match: fn _conn -> raise "boom" end)

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
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

      assert HTTPClient.fetch(TestServer.HTTP.url() <> "?a=2") == {:ok, "2"}
      assert HTTPClient.fetch(TestServer.HTTP.url() <> "?a=1") == {:ok, "1"}
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

      assert HTTPClient.fetch(TestServer.HTTP.url("/path") <> "?a=1") == {:ok, "2"}
      assert HTTPClient.fetch(TestServer.HTTP.url("/path") <> "?a=1", method: :post) == {:ok, "1"}
    end

    # `:httpd` has no HTTP/2 support
    unless System.get_env("HTTP_SERVER") == "Httpd" do
      test "with HTTP/2" do
        TestServer.HTTP.start!(scheme: :https)
        TestServer.HTTP.handle()

        assert HTTPClient.fetch(TestServer.HTTP.url(), protocol: :http2) == {:ok, "HTTP/2"}
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

        assert HTTPClient.fetch(TestServer.HTTP.url(),
                 protocol: :http2,
                 method: :post,
                 body: "test"
               ) == {:ok, "test"}
      end
    end
  end

  describe "plug/2" do
    defmodule InvalidPlug do
      def init(options), do: options
    end

    test "when instance not running" do
      instance = TestServer.HTTP.start!()
      :ok = TestServer.HTTP.stop(instance)

      assert_raise RuntimeError,
                   ~r/expected TestServer\.HTTP\.Instance .* to be running, but it was stopped at:/,
                   fn -> TestServer.HTTP.plug(instance, fn conn -> conn end) end
    end

    test "with invalid plug" do
      assert_raise ArgumentError,
                   "expected a 1-arity function, a Plug module, or a Plug module tuple, got: :invalid",
                   fn ->
                     TestServer.HTTP.plug(:invalid)
                   end

      assert_raise ArgumentError,
                   ~r/expected a 1-arity function, a Plug module, or a Plug module tuple, got: #{inspect(InvalidPlug)}/,
                   fn ->
                     TestServer.HTTP.plug(InvalidPlug)
                   end

      assert_raise ArgumentError,
                   ~r/expected a 1-arity function, a Plug module, or a Plug module tuple, got:/,
                   fn ->
                     TestServer.HTTP.plug({fn conn -> conn end, []})
                   end
    end

    test "with plug function" do
      TestServer.HTTP.plug(fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)

        %{conn | params: %{"plug" => "anonymous function", body: body}}
      end)

      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, URI.encode_query(&1.params)))

      assert {:ok, query} = HTTPClient.fetch(TestServer.HTTP.url(), method: :post)
      assert URI.decode_query(query) == %{"plug" => "anonymous function", "body" => "OK"}
    end

    test "with plug module" do
      defmodule ModulePlug do
        def init(options), do: options

        def call(conn, options), do: %{conn | params: %{"plug" => inspect({__MODULE__, options})}}
      end

      TestServer.HTTP.plug(ModulePlug)
      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, &1.params["plug"]))

      assert HTTPClient.fetch(TestServer.HTTP.url()) == {:ok, inspect({ModulePlug, []})}

      TestServer.HTTP.plug({ModulePlug, [a: 1]})
      TestServer.HTTP.handle(to: &Plug.Conn.resp(&1, 200, &1.params["plug"]))

      assert HTTPClient.fetch(TestServer.HTTP.url()) == {:ok, inspect({ModulePlug, [a: 1]})}
    end

    test "when plug function raises exception" do
      defmodule PlugFunctionRaiseTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.plug(fn _conn -> raise "boom" end)

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "(RuntimeError) boom"
      assert io =~ "anonymous fn/1 in TestServer.HTTPTest.PlugFunctionRaiseTest"
    end

    test "when plug function returning invalid result" do
      defmodule PlugFunctionInvalidResultTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.plug(fn _conn -> :invalid end)
          TestServer.HTTP.handle()

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "expected a Plug.Conn struct, got: :invalid"
    end

    test "when plug function returning halted conn" do
      defmodule PlugFunctionHaltedConnTest do
        use ExUnit.Case

        alias unquote(__MODULE__).HTTPClient

        test "fails" do
          TestServer.HTTP.start!(log: false)
          TestServer.HTTP.plug(fn conn -> Plug.Conn.halt(conn) end)
          TestServer.HTTP.handle()

          assert {:error, _} = HTTPClient.fetch(TestServer.HTTP.url())
        end
      end

      assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
      assert io =~ "cannot halt a connection because all requests must be processed"
    end
  end

  describe "cacerts/1" do
    test "when instance not running" do
      assert_raise RuntimeError, "expected TestServer.HTTP.Instance to be running", fn ->
        TestServer.HTTP.cacerts()
      end

      assert_raise RuntimeError,
                   ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it was stopped at:/,
                   fn ->
                     instance = TestServer.HTTP.start!()
                     :ok = TestServer.HTTP.stop()

                     TestServer.HTTP.cacerts(instance)
                   end
    end

    test "when not started with `scheme: :https` option" do
      TestServer.HTTP.start!()

      assert_raise RuntimeError,
                   ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running with \[scheme: :https\] option/,
                   fn -> TestServer.HTTP.cacerts() end
    end

    test "when started with `scheme: :https` option with `:tls` option with custom certificates" do
      tls_options = [] |> TestServer.put_tls_options() |> Keyword.fetch!(:tls)

      TestServer.HTTP.start!(scheme: :https, tls: tls_options)

      assert_raise RuntimeError,
                   ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> not to be running with \[tls: \[cacerts: \.\.\.\]\] option/,
                   fn -> TestServer.HTTP.cacerts() end
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

        url = TestServer.HTTP.url("/ws")

        headers = [
          {"connection", "Upgrade"},
          {"upgrade", "websocket"},
          {"sec-websocket-version", "13"},
          {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))}
        ]

        # Test the body response
        TestServer.HTTP.websocket("/ws")

        assert {:error, error} = HTTPClient.fetch(url, headers: headers)
        assert error.status == 501
        assert error.body == "WebSocket is not supported with httpd!"
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
                     ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it was stopped at:/,
                     fn -> TestServer.HTTP.websocket(instance, path: "/ws") end
      end

      test "with multiple instances" do
        TestServer.HTTP.start!()
        TestServer.HTTP.start!()

        assert_raise RuntimeError,
                     ~r/expected exactly one instance to be running, but got multiple instances; pass the instance to TestServer\.HTTP\.websocket\/2/,
                     fn -> TestServer.HTTP.websocket("/ws") end
      end

      test "with invalid options" do
        assert_raise ArgumentError, ~r/unknown keys/, fn ->
          TestServer.HTTP.websocket(invalid: :option)
        end

        assert_raise ArgumentError,
                     ~r/expected :match to be a 1-arity function, got: :invalid/,
                     fn ->
                       TestServer.HTTP.websocket(match: :invalid)
                     end

        assert_raise ArgumentError,
                     ~r/expected :match to be a 1-arity function, got: #Function/,
                     fn ->
                       TestServer.HTTP.websocket(match: fn _conn, _opts -> true end)
                     end

        assert_raise ArgumentError,
                     "expected :to to be a 1-arity function, a Plug module, or a Plug module tuple, got: :invalid",
                     fn ->
                       TestServer.HTTP.websocket(to: :invalid)
                     end

        assert_raise ArgumentError,
                     ~r/expected :to to be a 1-arity function, a Plug module, or a Plug module tuple, got: \#Function/,
                     fn ->
                       TestServer.HTTP.websocket(to: fn conn, _options -> conn end)
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

      test "with `:to` function returning a set conn" do
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
                     ~r/cannot send to websocket on TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> because no client has connected to it/,
                     fn -> TestServer.HTTP.websocket_send(websocket) end
      end

      test "with `:to` function" do
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
                     ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it was stopped at:/,
                     fn -> TestServer.HTTP.websocket_handle(websocket) end
      end

      test "when websocket doesn't exist" do
        instance = TestServer.HTTP.start!()
        websocket = {instance, make_ref()}

        assert_raise RuntimeError,
                     ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to have a websocket registered under \#Reference\<[0-9.]+\>/,
                     fn -> TestServer.HTTP.websocket_handle(websocket) end
      end

      test "with invalid options" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert_raise ArgumentError, ~r/unknown keys/, fn ->
          TestServer.HTTP.websocket_handle(websocket, invalid: :option)
        end

        assert_raise ArgumentError,
                     ~r/expected :match to be a 2-arity function, got: :invalid/,
                     fn ->
                       TestServer.HTTP.websocket_handle(websocket, match: :invalid)
                     end

        assert_raise ArgumentError,
                     ~r/expected :match to be a 2-arity function, got: #Function/,
                     fn ->
                       TestServer.HTTP.websocket_handle(websocket,
                         match: fn _frame, _state, _option -> true end
                       )
                     end

        assert_raise ArgumentError,
                     ~r/expected :to to be a 2-arity function, got: :invalid/,
                     fn ->
                       TestServer.HTTP.websocket_handle(websocket, to: :invalid)
                     end

        assert_raise ArgumentError,
                     ~r/expected :to to be a 2-arity function, got: #Function/,
                     fn ->
                       TestServer.HTTP.websocket_handle(websocket,
                         to: fn _frame, _option, state -> {:reply, {:text, "pong"}, state} end
                       )
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

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)

        assert io =~
                 ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to receive a frame for these websocket handlers before the test ended:/
      end

      test "when receiving unexpected frame" do
        defmodule WebSocketHandleUnexpectedFrameTest do
          use ExUnit.Case

          test "fails" do
            TestServer.HTTP.start!(log: false)
            TestServer.HTTP.websocket("/ws")

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketHandleUnexpectedFrameTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "received an unexpected WebSocket frame"
        assert io =~ "No active websocket handlers."
        refute io =~ "The following websocket handlers have been processed:"
        assert_receive {:frame, {:text, frame}}
        assert_io_websocket_message(io, frame)
      end

      test "when receiving unexpected frame before all handlers are processed" do
        defmodule WebSocketHandleUnexpectedBeforeProcessedTest do
          use ExUnit.Case

          test "fails" do
            _instance = TestServer.HTTP.start!(log: false)
            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket,
              match: fn _frame, _state -> false end
            )

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketHandleUnexpectedBeforeProcessedTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "received an unexpected WebSocket frame"
        refute io =~ "No active websocket handlers."
        refute io =~ "The following websocket handlers have been processed:"
        assert io =~ "Active websocket handlers:"
        assert io =~ ~r/test\/test_server\/http_test\.exs:\d+/
        assert io =~ "WebSocketHandleUnexpectedBeforeProcessedTest.\"test fails\"/1"
        assert_receive {:frame, {:text, frame}}
        assert_io_websocket_message(io, frame)
      end

      test "when receiving unexpected frame after all handlers are processed" do
        defmodule WebSocketHandleUnexpectedAfterProcessedTest do
          use ExUnit.Case

          test "fails" do
            _instance = TestServer.HTTP.start!(log: false)
            websocket = TestServer.HTTP.websocket("/ws")
            :ok = TestServer.HTTP.websocket_handle(websocket)

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
            assert WebSocketClient.receive_frame(client) == {:ok, {:text, "ping"}}
            assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketHandleUnexpectedAfterProcessedTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "received an unexpected WebSocket frame"
        assert io =~ "No active websocket handlers."
        assert io =~ "The following websocket handlers have been processed:"
        assert_receive {:frame, {:text, frame}}
        assert_io_websocket_message(io, frame)
      end

      test "when receiving control frame" do
        websocket = TestServer.HTTP.websocket("/ws")
        :ok = TestServer.HTTP.websocket_handle(websocket)

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
        assert WebSocketClient.send_frame(client, {:pong, "client-pong"}) == :ok
        assert WebSocketClient.send_frame(client, {:ping, "probe"}) == :ok
        assert WebSocketClient.receive_frame(client) == {:ok, {:pong, "probe"}}
        assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
        assert WebSocketClient.receive_frame(client) == {:ok, {:text, "ping"}}
      end

      test "when `:match` function raises exception" do
        defmodule WebSocketHandleMatchFunctionRaiseTest do
          use ExUnit.Case

          test "fails" do
            _instance = TestServer.HTTP.start!(log: false)
            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket,
              match: fn _frame, _state -> raise "boom" end
            )

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketHandleMatchFunctionRaiseTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "(RuntimeError) boom"
        assert io =~ "anonymous fn/2 in TestServer.HTTPTest.WebSocketHandleMatchFunctionRaiseTest"
        assert_receive {:frame, {:text, frame}}
        assert_io_websocket_message(io, frame)
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
        assert WebSocketClient.send_frame(client, {:text, "second"}) == :ok
        assert WebSocketClient.receive_frame(client) == {:ok, {:text, "second"}}
        assert WebSocketClient.send_frame(client, {:text, "first"}) == :ok
        assert WebSocketClient.receive_frame(client) == {:ok, {:text, "pong"}}
      end

      test "when `:to` function raises exception" do
        defmodule WebSocketHandleToFunctionRaiseTest do
          use ExUnit.Case

          test "fails" do
            _instance = TestServer.HTTP.start!(log: false)
            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket,
              to: fn _frame, _state -> raise "boom" end
            )

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketHandleToFunctionRaiseTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "(RuntimeError) boom"
        assert io =~ "anonymous fn/2 in TestServer.HTTPTest.WebSocketHandleToFunctionRaiseTest"
        assert_receive {:frame, {:text, frame}}
        assert_io_websocket_message(io, frame)
      end

      test "when `:to` function returns invalid response" do
        defmodule WebSocketHandleToFunctionInvalidResponseTest do
          use ExUnit.Case

          test "fails" do
            _instance = TestServer.HTTP.start!(log: false)
            websocket = TestServer.HTTP.websocket("/ws")

            TestServer.HTTP.websocket_handle(websocket,
              to: fn _frame, _state -> :invalid end
            )

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
            assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketHandleToFunctionInvalidResponseTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "(RuntimeError) expected callback response to be one of:"
        assert io =~ "Got: :invalid"
        assert_receive {:frame, {:text, frame}}
        assert_io_websocket_message(io, frame)
      end

      test "with `:to` function" do
        _instance = TestServer.HTTP.start!(log: false)
        websocket = TestServer.HTTP.websocket("/ws")

        TestServer.HTTP.websocket_handle(websocket,
          to: fn {:text, _any}, state -> {:reply, {:text, "function called"}, state} end
        )

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
        assert WebSocketClient.send_frame(client, {:text, "ping"}) == :ok
        assert {:ok, frame} = WebSocketClient.receive_frame(client)
        assert frame == {:text, "function called"}
      end
    end

    describe "websocket_send/2" do
      test "when instance not running" do
        instance = TestServer.HTTP.start!()
        websocket = TestServer.HTTP.websocket("/ws")
        :ok = TestServer.HTTP.stop(instance)

        assert_raise RuntimeError,
                     ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to be running, but it was stopped at:/,
                     fn -> TestServer.HTTP.websocket_send(websocket) end
      end

      test "with invalid options" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert {:ok, _client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        assert_raise ArgumentError, ~r/unknown keys/, fn ->
          TestServer.HTTP.websocket_send(websocket, invalid: :option)
        end

        assert_raise ArgumentError,
                     ~r/expected :to to be a 1-arity function, got: :invalid/,
                     fn ->
                       TestServer.HTTP.websocket_send(websocket, to: :invalid)
                     end

        assert_raise ArgumentError,
                     ~r/expected :to to be a 1-arity function, got: #Function/,
                     fn ->
                       TestServer.HTTP.websocket_send(websocket,
                         to: fn _options, state -> {:ok, state} end
                       )
                     end
      end

      test "when client has not connected" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert_raise RuntimeError,
                     ~r/cannot send to websocket on TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> because no client has connected to it/,
                     fn -> TestServer.HTTP.websocket_send(websocket) end

        TestServer.HTTP.stop()
      end

      test "when connection doesn't exist" do
        instance = TestServer.HTTP.start!()
        connection = {instance, make_ref()}

        assert_raise RuntimeError,
                     ~r/expected TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> to have a websocket registered under \#Reference\<[0-9.]+\>/,
                     fn -> TestServer.HTTP.websocket_send(connection) end
      end

      test "when client has disconnected" do
        instance = TestServer.HTTP.start!()
        websocket = TestServer.HTTP.websocket("/ws")

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
        assert [%{owner: owner_pid}] = TestServer.HTTP.Instance.websockets(instance)
        assert monitor = Process.monitor(owner_pid)
        assert WebSocketClient.close(client) == :ok
        assert_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason}

        assert_raise RuntimeError,
                     ~r/cannot send to websocket on TestServer\.HTTP\.Instance \#PID\<[0-9.]+\> because the client has disconnected/,
                     fn -> TestServer.HTTP.websocket_send(websocket) end
      end

      test "sends" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        TestServer.HTTP.websocket_send(websocket)

        assert WebSocketClient.receive_frame(client) == {:ok, {:text, "ping"}}
      end

      test "when `:to` function raises exception" do
        defmodule WebSocketSendToFunctionRaiseTest do
          use ExUnit.Case

          test "fails" do
            _instance = TestServer.HTTP.start!(log: false)
            websocket = TestServer.HTTP.websocket("/ws")

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

            TestServer.HTTP.websocket_send(websocket, to: fn _state -> raise "boom" end)

            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketSendToFunctionRaiseTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "(RuntimeError) boom"
        assert io =~ "anonymous fn/1 in TestServer.HTTPTest.WebSocketSendToFunctionRaiseTest"
        assert_receive {:frame, {:text, message}}
        assert_io_websocket_message(io, message)
      end

      test "when `:to` function returns an invalid response" do
        defmodule WebSocketSendToInvalidResponseTest do
          use ExUnit.Case

          test "fails" do
            _instance = TestServer.HTTP.start!(log: false)
            websocket = TestServer.HTTP.websocket("/ws")

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

            TestServer.HTTP.websocket_send(websocket, to: fn _state -> :invalid end)

            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketSendToInvalidResponseTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "(RuntimeError) expected callback response to be one of:"
        assert io =~ "Got: :invalid"
        assert_receive {:frame, {:text, message}}
        assert_io_websocket_message(io, message)
      end

      test "when `:to` function returns `{:reply, frame, state}` with invalid frame" do
        defmodule WebSocketSendToInvalidFrameTest do
          use ExUnit.Case

          test "fails" do
            _instance = TestServer.HTTP.start!(log: false)
            websocket = TestServer.HTTP.websocket("/ws")

            assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

            TestServer.HTTP.websocket_send(websocket,
              to: fn state -> {:reply, :invalid, state} end
            )

            assert {:ok, frame} = WebSocketClient.receive_frame(client)

            send(__MODULE__, {:frame, frame})
          end
        end

        Process.register(self(), WebSocketSendToInvalidFrameTest)

        assert io = capture_io(fn -> assert %{failures: 1} = ExUnit.run() end)
        assert io =~ "(RuntimeError) expected callback response to be one of:"
        assert io =~ "Got: {:reply, :invalid, %{}}"
        assert_receive {:frame, {:text, message}}
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

        assert WebSocketClient.receive_frame(client) == {:ok, {:text, "pong"}}
      end

      test "when `:to` function returns `{:reply, {:binary, binary}, state}`" do
        websocket = TestServer.HTTP.websocket("/ws")

        assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

        TestServer.HTTP.websocket_send(websocket,
          to: fn state ->
            {:reply, {:binary, "pong"}, state}
          end
        )

        assert WebSocketClient.receive_frame(client) == {:ok, {:binary, "pong"}}
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

        assert WebSocketClient.receive_frame(client) == {:ok, {:text, inspect(%{a: 1})}}
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

  defmodule HTTPClient do
    def fetch(url, options \\ []) do
      protocol = Keyword.get(options, :protocol, :http1)
      options = Keyword.delete(options, :protocol)

      case protocol do
        :http2 -> do_http2_request(url, options)
        :http1 -> do_http1_request(url, options)
      end
    end

    defp do_http1_request(url, options) do
      url = String.to_charlist(url)

      headers =
        options
        |> Keyword.get(:headers, [])
        |> Enum.map(fn {name, value} ->
          {String.to_charlist(name), String.to_charlist(value)}
        end)

      options
      |> Keyword.get(:method, :get)
      |> case do
        :post -> {:post, {url, headers, ~c"plain/text", ~c"OK"}}
        :get -> {:get, {url, headers}}
      end
      |> then(fn {method, request} ->
        httpc_options = Keyword.take(options, [:ssl])

        :httpc.set_options(ipfamily: Keyword.get(options, :ipfamily, :inet))
        :httpc.request(method, request, httpc_options, [])
      end)
      |> case do
        {:ok, {{_, 200, _}, _headers, body}} ->
          {:ok, IO.iodata_to_binary(body)}

        {:ok, {{_, status, _}, _headers, body}} ->
          {:error, %{status: status, body: IO.iodata_to_binary(body)}}

        {:error, error} ->
          {:error, error}
      end
    end

    if System.get_env("HTTP_SERVER") == "Httpd" do
      defp do_http2_request(_url, _options) do
        {:error, :http2_not_supported}
      end
    else
      defp do_http2_request(url, options) do
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

          {:ok, %{status: status, body: body}} ->
            {:error, %{status: status, body: body}}

          {:error, %Finch.Error{reason: :pool_not_available}} ->
            :timer.sleep(10)

            do_http2_request(url, options)

          {:error, error} ->
            {:error, error}
        end
      end
    end
  end

  defmodule WebSocketClient do
    use WebSockex

    def start_link(url) do
      WebSockex.start_link(url, __MODULE__, self())
    end

    def handle_connect(_conn, caller) do
      {:ok, caller}
    end

    def handle_frame(frame, caller) do
      send(caller, {__MODULE__, self(), frame})

      {:ok, caller}
    end

    def handle_cast(:close, state) do
      {:close, {1_000, "Bye"}, state}
    end

    def handle_pong(frame, caller) do
      send(caller, {__MODULE__, self(), frame})

      {:ok, caller}
    end

    def send_frame(client, frame) do
      WebSockex.send_frame(client, frame)
    end

    def receive_frame(client) do
      receive do
        {__MODULE__, ^client, frame} -> {:ok, frame}
      after
        100 -> {:error, :timeout}
      end
    end

    def close(client) do
      WebSockex.cast(client, :close)
    end
  end
end
