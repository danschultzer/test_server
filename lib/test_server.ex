defmodule TestServer do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias Plug.Conn
  alias TestServer.{Instance, InstanceManager}

  @type instance :: pid()
  @type route :: reference()
  @type stacktrace :: list()
  @type websocket_socket :: {instance(), route()}
  @type websocket_frame :: {atom(), any()}
  @type websocket_state :: any()
  @type websocket_reply ::
          {:reply, websocket_frame(), websocket_state()} | {:ok, websocket_state()}

  @doc """
  Start a test server instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`             - integer of port number, defaults to random port
      that can be opened;
    * `:scheme`           - an atom for the http scheme. Defaults to `:http`;
    * `:http_server`      - HTTP server configuration. Defaults to
      `{TestServer.HTTPServer.Bandit, []}`,
      `{TestServer.HTTPServer.Plug.Cowboy, []}`, or
      `{TestServer.HTTPServer.Httpd, []}` depending on which web server is
      available in the project dependencies;
    * `:tls`              - Passthru options for TLS configuration handled by
      the webserver;
    * `:ipfamily`         - The IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet`;

  ## Examples

      TestServer.start(
        scheme: :https,
        ipfamily: :inet6,
        http_server: {TestServer.HTTPServer.Bandit, [ip: :any]}
      )

      TestServer.add("/",
        to: fn conn ->
          assert conn.remote_ip == {0, 0, 0, 0, 0, 65_535, 32_512, 1}

          Plug.Conn.resp(conn, 200, to_string(Plug.Conn.get_http_protocol(conn)))
        end
      )

      req_opts = [
        connect_options: [
          transport_opts: [cacerts: TestServer.x509_suite().cacerts],
          protocols: [:http2]
        ]
      ]

      assert {:ok, %Req.Response{status: 200, body: "HTTP/2"}} =
              Req.get(TestServer.url(), req_opts)
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(options \\ []) do
    case ExUnit.fetch_test_supervisor() do
      {:ok, sup} ->
        start_with_ex_unit(options, sup)

      :error ->
        raise ArgumentError, "can only be called in a test process"
    end
  end

  defp start_with_ex_unit(options, _sup) do
    [_first_module_entry | stacktrace] = get_stacktrace()

    case InstanceManager.start_instance(self(), stacktrace, options) do
      {:ok, instance} ->
        put_ex_unit_on_exit_callback(instance)

        {:ok, instance}

      {:error, error} ->
        raise_start_failure({:error, error})
    end
  end

  defp put_ex_unit_on_exit_callback(instance) do
    ExUnit.Callbacks.on_exit(fn ->
      case Process.alive?(instance) do
        true ->
          verify_routes!(instance)
          verify_websocket_handlers!(instance)
          stop(instance)

        false ->
          :ok
      end
    end)
  end

  defp raise_start_failure({:error, {{:EXIT, reason}, _spec}}) do
    raise_start_failure({:error, reason})
  end

  defp raise_start_failure({:error, error}) do
    raise """
    EXIT when starting #{inspect(__MODULE__.Instance)}:

    #{Exception.format_exit(error)}
    """
  end

  defp verify_routes!(instance) do
    instance
    |> Instance.routes()
    |> Enum.reject(& &1.suspended)
    |> case do
      [] ->
        :ok

      active_routes ->
        raise """
        #{Instance.format_instance(instance)} did not receive a request for these routes before the test ended:

        #{Instance.format_routes(active_routes)}
        """
    end
  end

  defp verify_websocket_handlers!(instance) do
    instance
    |> Instance.websocket_handlers()
    |> Enum.reject(& &1.suspended)
    |> case do
      [] ->
        :ok

      active_websocket_handlers ->
        raise """
        #{Instance.format_instance(instance)} did not receive a frame for these websocket handlers before the test ended:

        #{Instance.format_websocket_handlers(active_websocket_handlers)}
        """
    end
  end

  @doc """
  Shuts down the current test server.

  ## Examples

      TestServer.start()
      url = TestServer.url()
      TestServer.stop()

      assert {:error, %Req.TransportError{}} = Req.get(url, retry: false)
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(fetch_instance!())

  @doc """
  Shuts down a test server instance.
  """
  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(instance) do
    instance_alive!(instance)

    InstanceManager.stop_instance(instance)
  end

  defp instance_alive!(instance) do
    case Process.alive?(instance) do
      true -> :ok
      false -> raise "#{Instance.format_instance(instance)} is not running"
    end
  end

  @doc """
  Gets current test server instance if running.

  ## Examples

      refute TestServer.get_instance()

      {:ok, instance} = TestServer.start()

      assert TestServer.get_instance() == instance
  """
  @spec get_instance() :: pid() | nil
  def get_instance do
    case fetch_instance(false) do
      {:ok, instance} -> instance
      :error -> nil
    end
  end

  @spec url() :: binary()
  def url, do: url("")

  @spec url(binary() | keyword() | pid()) :: binary()
  def url(uri) when is_binary(uri), do: url(uri, [])
  def url(opts) when is_list(opts), do: url("", opts)
  def url(instance) when is_pid(instance), do: url(instance, "", [])

  @doc """
  Produces a URL for current test server.

  ## Options
    * `:host` - binary host value, it'll be added to inet for IP `127.0.0.1` and `::1`, defaults to `"localhost"`;

  ## Examples

      TestServer.start(port: 4444)

      assert TestServer.url() == "http://localhost:4444"
      assert TestServer.url("/test") == "http://localhost:4444/test"
      assert TestServer.url(host: "example.com") == "http://example.com:4444"
  """
  @spec url(binary(), keyword()) :: binary()
  def url(uri, opts) when is_binary(uri), do: url(fetch_instance!(), uri, opts)

  @spec url(pid(), binary()) :: binary()
  def url(instance, uri) when is_pid(instance), do: url(instance, uri, [])

  @doc """
  Produces a URL for a test server instance.

  See `url/2` for options.
  """
  @spec url(pid(), binary(), keyword()) :: binary()
  def url(instance, uri, opts) do
    instance_alive!(instance)

    unless is_nil(opts[:host]) or is_binary(opts[:host]),
      do: raise("Invalid host, got: #{inspect(opts[:host])}")

    domain = maybe_enable_host(opts[:host])
    options = Instance.get_options(instance)

    "#{Keyword.fetch!(options, :scheme)}://#{domain}:#{Keyword.fetch!(options, :port)}#{uri}"
  end

  defp fetch_instance! do
    case fetch_instance() do
      :error -> raise "No current #{inspect(Instance)} running"
      {:ok, instance} -> instance
    end
  end

  defp fetch_instance(function_accepts_instance_arg \\ true) do
    case InstanceManager.get_by_caller(self()) do
      nil ->
        :error

      [instance] ->
        {:ok, instance}

      [_instance | _rest] = instances ->
        [{m, f, a, _} | _stacktrace] = get_stacktrace()

        message =
          case function_accepts_instance_arg do
            true ->
              "Multiple #{inspect(Instance)}'s running, please pass instance to `#{inspect(m)}.#{f}/#{a}`."

            false ->
              "Multiple #{inspect(Instance)}'s running."
          end

        formatted_instances =
          instances
          |> Enum.map(&{&1, Instance.get_options(&1)})
          |> Enum.with_index()
          |> Enum.map_join("\n\n", fn {{instance, options}, index} ->
            """
            ##{index + 1}: #{Instance.format_instance(instance)}
                #{Enum.map_join(options[:stacktrace], "\n    ", &Exception.format_stacktrace_entry/1)}")}
            """
          end)

        raise """
        #{message}

        #{formatted_instances}
        """
    end
  end

  defp maybe_enable_host(nil), do: "localhost"

  defp maybe_enable_host(host) do
    :inet_db.set_lookup([:file, :dns])
    :inet_db.add_host({127, 0, 0, 1}, [String.to_charlist(host)])
    :inet_db.add_host({0, 0, 0, 0, 0, 0, 0, 1}, [String.to_charlist(host)])

    host
  end

  @spec add(binary()) :: :ok
  def add(uri), do: add(uri, [])

  @doc """
  Adds a route to the current test server.

  Matching routes are handled FIFO (first in, first out). Any requests to
  routes not added to the TestServer and any routes that isn't matched will
  raise an error in the test case.

  ## Options

    * `:via`       - matches the route against some specific HTTP method(s)
      specified as an atom, like `:get` or `:put`, or a list, like `[:get, :post]`.
    * `:match`     - an anonymous function that will be called to see if a
      route matches, defaults to matching with arguments of uri and `:via` option.
    * `:to`        - a Plug or anonymous function that will be called when the
      route matches, defaults to return the http scheme.

  ## Examples

      TestServer.add("/",
        match: fn conn ->
          conn.query_params["a"] == "1"
        end,
        to: fn conn ->
          Plug.Conn.resp(conn, 200, "a = 1")
        end)

      TestServer.add("/", to: &Plug.Conn.resp(&1, 200, "PONG"))
      TestServer.add("/")

      assert {:ok, %Req.Response{status: 200, body: "PONG"}} = Req.get(TestServer.url("/"))
      assert {:ok, %Req.Response{status: 200, body: "HTTP/1.1"}} = Req.post(TestServer.url("/"))
      assert {:ok, %Req.Response{status: 200, body: "a = 1"}} = Req.get(TestServer.url("/?a=1"))
  """
  @spec add(binary(), keyword()) :: :ok
  def add(uri, options) when is_binary(uri) do
    {:ok, instance} = autostart()

    add(instance, uri, options)
  end

  @spec add(pid(), binary()) :: :ok
  def add(instance, uri) when is_pid(instance) and is_binary(uri), do: add(instance, uri, [])

  @doc """
  Adds a route to a test server instance.

  See `add/2` for options.
  """
  @spec add(pid(), binary(), keyword()) :: :ok
  def add(instance, uri, options) when is_pid(instance) and is_binary(uri) and is_list(options) do
    instance_alive!(instance)

    [_first_module_entry | stacktrace] = get_stacktrace()

    options = Keyword.put_new(options, :to, &default_response_handler/1)

    {:ok, _route} = Instance.register(instance, {:plug_router_to, {uri, options, stacktrace}})

    :ok
  end

  defp get_stacktrace do
    {:current_stacktrace, [{Process, :info, _, _} | stacktrace]} =
      Process.info(self(), :current_stacktrace)

    first_module_entry =
      stacktrace
      |> Enum.reverse()
      |> Enum.find(fn {mod, _, _, _} -> mod == __MODULE__ end)

    [first_module_entry] ++ prune_stacktrace(stacktrace)
  end

  # Remove TestServer
  defp prune_stacktrace([{__MODULE__, _, _, _} | t]), do: prune_stacktrace(t)

  # Assertions can pop-up in the middle of the stack
  defp prune_stacktrace([{ExUnit.Assertions, _, _, _} | t]), do: prune_stacktrace(t)

  # As soon as we see a Runner, it is time to ignore the stacktrace
  defp prune_stacktrace([{ExUnit.Runner, _, _, _} | _]), do: []

  # All other cases
  defp prune_stacktrace([h | t]), do: [h | prune_stacktrace(t)]
  defp prune_stacktrace([]), do: []

  defp autostart do
    case fetch_instance() do
      :error -> start()
      {:ok, instance} -> {:ok, instance}
    end
  end

  defp default_response_handler(conn) do
    Conn.resp(conn, 200, to_string(Conn.get_http_protocol(conn)))
  end

  @doc """
  Adds a plug to the current test server.

  This plug will be called for all requests before route is matched.

  ## Examples

      TestServer.plug(MyPlug)

      TestServer.plug(fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn, [])

        %{conn | body_params: Jason.decode!(body)}
      end)
  """
  @spec plug(module() | function()) :: :ok
  def plug(plug) do
    {:ok, instance} = autostart()

    plug(instance, plug)
  end

  @doc """
  Adds a route to a test server instance.

  See `plug/1` for options.
  """
  @spec plug(pid(), module() | function()) :: :ok
  def plug(instance, plug) do
    [_first_module_entry | stacktrace] = get_stacktrace()

    {:ok, _plug} = Instance.register(instance, {:plug, {plug, stacktrace}})

    :ok
  end

  @doc """
  Fetches the generated x509 suite for the current test server.

  ## Examples

      TestServer.start(scheme: :https)
      TestServer.add("/")

      cacerts = TestServer.x509_suite().cacerts
      req_opts = [connect_options: [transport_opts: [cacerts: cacerts]]]

      assert {:ok, %Req.Response{status: 200, body: "HTTP/1.1"}} =
              Req.get(TestServer.url(), req_opts)
  """
  @spec x509_suite() :: term()
  def x509_suite, do: x509_suite(fetch_instance!())

  @doc """
  Fetches the generated x509 suite for a test server instance.
  """
  @spec x509_suite(pid()) :: term()
  def x509_suite(instance) do
    instance_alive!(instance)

    options = Instance.get_options(instance)

    cond do
      not (options[:scheme] == :https) ->
        raise "#{Instance.format_instance(instance)} is not running with `[scheme: :https]` option"

      not Keyword.has_key?(options, :x509_suite) ->
        raise "#{Instance.format_instance(instance)} is running with custom SSL"

      true ->
        options[:x509_suite]
    end
  end

  @spec websocket_init(binary()) :: {:ok, websocket_socket()} | {:error, term()}
  def websocket_init(uri) when is_binary(uri), do: websocket_init(uri, [])

  @doc """
  Adds a websocket route to current test server.

  ## Options

  Takes the same options as `add/2`, except `:to`.

  ## Examples

      {:ok, socket} = TestServer.websocket_init("/ws")
      TestServer.websocket_handle(socket)

      assert {:ok, client} = WebSocketClient.start_link(TestServer.url("/ws"))
      assert WebSocketClient.send_message(client, "echo") == {:ok, "echo"}

  `:via` and `:match` are called during the HTTP handshake:

      TestServer.websocket_init("/ws", via: :get, match: fn conn ->
        conn.params["token"] == "secret"
      end)

      assert {:ok, _client} = WebSocketClient.start_link(TestServer.url("/ws?token=secret"))
  """
  @spec websocket_init(binary(), keyword()) :: {:ok, websocket_socket()}
  def websocket_init(uri, options) when is_binary(uri) do
    {:ok, instance} = autostart()

    websocket_init(instance, uri, options)
  end

  @spec websocket_init(pid(), binary()) :: {:ok, websocket_socket()}
  def websocket_init(instance, uri) when is_pid(instance) and is_binary(uri) do
    websocket_init(instance, uri, [])
  end

  @doc """
  Adds a websocket route to a test server.

  See `websocket_init/2` for options.
  """
  @spec websocket_init(pid(), binary(), keyword()) :: {:ok, websocket_socket()}
  def websocket_init(instance, uri, options) do
    instance_alive!(instance)

    if Keyword.has_key?(options, :to), do: raise(ArgumentError, "`:to` is an invalid option")

    [_first_module_entry | stacktrace] = get_stacktrace()

    options = Keyword.put(options, :to, :websocket)

    {:ok, %{ref: ref}} =
      Instance.register(instance, {:plug_router_to, {uri, options, stacktrace}})

    {:ok, {instance, ref}}
  end

  @spec websocket_handle(websocket_socket()) :: :ok | {:error, term()}
  def websocket_handle(socket), do: websocket_handle(socket, [])

  @doc """
  Adds a message handler to a websocket instance.

  Messages are matched FIFO (first in, first out). Any messages not expected by
  TestServer or any message expectations not receiving a message will raise an
  error in the test case.

  ## Options

    * `:match`     - an anonymous function that will be called to see if a
      message matches, defaults to matching anything.
    * `:to`        - an anonymous function that will be called when the message
      matches, defaults to returning received message.

  ## Examples

      {:ok, socket} = TestServer.websocket_init("/ws")

      TestServer.websocket_handle(
        socket,
        to: fn _frame, state ->
          {:reply, {:text, "pong"}, state}
        end,
        match: fn frame, _state ->
          frame == {:text, "ping"}
        end)

      TestServer.websocket_handle(socket)

      {:ok, client} = WebSocketClient.start_link(TestServer.url("/ws"))

      assert WebSocketClient.send_message(client, "echo") == {:ok, "echo"}
      assert WebSocketClient.send_message(client, "ping") == {:ok, "pong"}
  """
  @spec websocket_handle(websocket_socket(), keyword()) :: :ok
  def websocket_handle({instance, _route_ref} = socket, options) do
    instance_alive!(instance)

    [_first_module_entry | stacktrace] = get_stacktrace()

    options = Keyword.put_new(options, :to, &default_websocket_handle/2)

    {:ok, _handler} = Instance.register(socket, {:websocket, {:handle, options, stacktrace}})

    :ok
  end

  defp default_websocket_handle(frame, state),
    do: {:reply, frame, state}

  @doc """
  Sends an message to a websocket instance.

  ## Examples

      {:ok, socket} = TestServer.websocket_init("/ws")
      {:ok, client} = WebSocketClient.start_link(TestServer.url("/ws"))

      assert TestServer.websocket_info(socket, fn state ->
        {:reply, {:text, "hello"}, state}
      end) == :ok

      assert WebSocketClient.receive_message(client) == {:ok, "hello"}
  """
  @spec websocket_info(websocket_socket(), function() | nil) :: :ok
  def websocket_info({instance, _route_ref} = socket, callback \\ nil)
      when is_function(callback) or is_nil(callback) do
    instance_alive!(instance)

    [_first_module_entry | stacktrace] = get_stacktrace()

    callback = callback || (&default_websocket_info/1)

    for pid <- Instance.active_websocket_connections(socket) do
      send(pid, {callback, stacktrace})
    end

    :ok
  end

  defp default_websocket_info(state), do: {:reply, {:text, "ping"}, state}
end
