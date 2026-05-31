defmodule TestServer.HTTP do
  @external_resource "lib/test_server/http/README.md"
  @moduledoc "lib/test_server/http/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias Plug.Conn
  alias TestServer.HTTP.{Instance, Server}

  @type route :: reference()
  @type handler_fun :: (conn :: Plug.Conn.t() -> Plug.Conn.t())
  @type plug_module :: module()
  @type plug_fun :: (conn :: Plug.Conn.t() -> Plug.Conn.t())
  @type match_fun :: (conn :: Plug.Conn.t() -> boolean())

  @type websocket_socket :: {TestServer.instance(), route()}
  @type websocket_frame :: {atom(), term()}
  @type websocket_state :: term()
  @type websocket_handler_fun :: (frame :: websocket_frame(), state :: websocket_state() ->
                                    websocket_reply())
  @type websocket_match_fun :: (frame :: websocket_frame(), state :: websocket_state() ->
                                  boolean())
  @type websocket_info_fun :: (state :: websocket_state() -> websocket_reply())

  @type websocket_reply ::
          {:reply, websocket_frame(), websocket_state()} | {:ok, websocket_state()}

  @type x509_suite :: %{cert: binary(), cacerts: [binary()]}

  @doc """
  Start a test server HTTP instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`             - integer of port number, defaults to random port
      that can be opened;

    * `:scheme`           - an atom for the http scheme. Defaults to `:http`;

    * `:http_server`      - HTTP server configuration. Defaults to
      `{TestServer.HTTP.Server.Bandit, []}`,
      `{TestServer.HTTP.Server.Plug.Cowboy, []}`, or
      `{TestServer.HTTP.Server.Httpd, []}` depending on which web server is
      available in the project dependencies;

    * `:tls`              - Passthru options for TLS configuration handled by
      the webserver;

    * `:ipfamily`         - The IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet`;

    * `:suppress_warning` - Suppresses IO warnings on expectation failures
      related to this instance. Defaults to `false`;

  ## Examples

      TestServer.HTTP.start(
        scheme: :https,
        ipfamily: :inet6,
        http_server: {TestServer.HTTP.Server.Bandit, [ip: :any]}
      )

      TestServer.HTTP.add("/",
        to: fn conn ->
          assert conn.remote_ip == {0, 0, 0, 0, 0, 65_535, 32_512, 1}

          Plug.Conn.resp(conn, 200, to_string(Plug.Conn.get_http_protocol(conn)))
        end
      )

      req_options = [
        connect_options: [
          transport_opts: [cacerts: TestServer.HTTP.x509_suite().cacerts],
          protocols: [:http2]
        ]
      ]

      assert {:ok, %Req.Response{status: 200, body: "HTTP/2"}} =
              Req.get(TestServer.HTTP.url(), req_options)
  """
  @spec start(keyword()) :: {:ok, TestServer.instance()}
  def start(options \\ []) do
    TestServer.start_instance(__MODULE__, options, &verify_instance!/1)
  end

  defp verify_instance!(instance) do
    verify_routes!(instance)
    verify_websocket_handlers!(instance)
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
        #{TestServer.format_instance(__MODULE__, instance)} did not receive a request for these routes before the test ended:

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
        #{TestServer.format_instance(__MODULE__, instance)} did not receive a frame for these websocket handlers before the test ended:

        #{Instance.format_websocket_handlers(active_websocket_handlers)}
        """
    end
  end

  @doc """
  Shuts down the current test server.

  ## Examples

      TestServer.HTTP.start()
      url = TestServer.HTTP.url()
      TestServer.HTTP.stop()

      assert {:error, %Req.TransportError{}} = Req.get(url, retry: false)
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Shuts down a test server instance.
  """
  @spec stop(TestServer.instance()) :: :ok | {:error, term()}
  def stop(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    :ok = Server.stop(Instance.get_options(instance))

    TestServer.stop_instance(__MODULE__, instance)
  end

  @spec url() :: binary()
  def url, do: url("")

  @spec url(binary() | keyword() | TestServer.instance()) :: binary()
  def url(uri) when is_binary(uri), do: url(uri, [])
  def url(options) when is_list(options), do: url("", options)
  def url(instance) when is_pid(instance), do: url(instance, "", [])

  @doc """
  Produces a URL for current test server.

  ## Options

    * `:host` - binary host value, it'll be added to inet for IP `127.0.0.1`
      and `::1`, defaults to `"localhost"`;

  ## Examples

      TestServer.HTTP.start(port: 4444)

      assert TestServer.HTTP.url() == "http://localhost:4444"
      assert TestServer.HTTP.url("/test") == "http://localhost:4444/test"
      assert TestServer.HTTP.url(host: "example.com") == "http://example.com:4444"
  """
  @spec url(binary(), keyword()) :: binary()
  def url(uri, options) when is_binary(uri),
    do: url(TestServer.fetch_instance!(__MODULE__), uri, options)

  @spec url(TestServer.instance(), binary()) :: binary()
  def url(instance, uri) when is_pid(instance), do: url(instance, uri, [])

  @doc """
  Produces a URL for a test server instance.

  See `url/2` for options.
  """
  @spec url(TestServer.instance(), binary(), keyword()) :: binary()
  def url(instance, uri, options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    domain = TestServer.get_host(options)
    options = Instance.get_options(instance)

    "#{Keyword.fetch!(options, :scheme)}://#{domain}:#{Keyword.fetch!(options, :port)}#{uri}"
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
      specified as an atom, like `:get` or `:put`, or a list, like `[:get, :post]`;

    * `:match`     - an `t:match_fun/0` function that returns a boolean.
      Defaults to matching with arguments of uri and `:via` option;

    * `:to`        - a `t:handler_fun/0` or `t:plug_module/0` that will be
      called when the route matches, defaults to return the http scheme;

  ## Examples

      TestServer.HTTP.add("/",
        match: fn conn ->
          conn.query_params["a"] == "1"
        end,
        to: fn conn ->
          Plug.Conn.resp(conn, 200, "a = 1")
        end)

      TestServer.HTTP.add("/", to: &Plug.Conn.resp(&1, 200, "PONG"))
      TestServer.HTTP.add("/")

      assert {:ok, %Req.Response{status: 200, body: "PONG"}} = Req.get(TestServer.HTTP.url("/"))
      assert {:ok, %Req.Response{status: 200, body: "HTTP/1.1"}} = Req.post(TestServer.HTTP.url("/"))
      assert {:ok, %Req.Response{status: 200, body: "a = 1"}} = Req.get(TestServer.HTTP.url("/?a=1"))
  """
  @spec add(binary(), keyword()) :: :ok
  def add(uri, options) when is_binary(uri) do
    {:ok, instance} = TestServer.autostart_instance(__MODULE__)

    add(instance, uri, options)
  end

  @spec add(TestServer.instance(), binary()) :: :ok
  def add(instance, uri) when is_pid(instance) and is_binary(uri), do: add(instance, uri, [])

  @doc """
  Adds a route to a test server instance.

  See `add/2` for options.
  """
  @spec add(TestServer.instance(), binary(), keyword()) :: :ok
  def add(instance, uri, options) when is_pid(instance) and is_binary(uri) and is_list(options) do
    options = Keyword.put_new(options, :to, &default_response_handler/1)

    {:ok, _route} = register_route(instance, uri, options)

    :ok
  end

  defp register_route(instance, uri, options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_register_route, _first_module_entry | stacktrace] =
      TestServer.get_pruned_stacktrace(__MODULE__)

    Instance.register(instance, {:plug_router_to, {uri, options, stacktrace}})
  end

  defp default_response_handler(conn) do
    Conn.resp(conn, 200, to_string(Conn.get_http_protocol(conn)))
  end

  @doc """
  Adds a plug to the current test server.

  This plug will be called for all requests before route is matched.

  ## Examples

      TestServer.HTTP.plug(MyPlug)

      TestServer.HTTP.plug(fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn, [])

        %{conn | body_params: Jason.decode!(body)}
      end)
  """
  @spec plug(plug_module() | plug_fun()) :: :ok
  def plug(plug) do
    {:ok, instance} = TestServer.autostart_instance(__MODULE__)

    plug(instance, plug)
  end

  @doc """
  Adds a plug to a test server instance.

  See `plug/1` for more.
  """
  @spec plug(TestServer.instance(), plug_module() | plug_fun()) :: :ok
  def plug(instance, plug) do
    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)

    {:ok, _plug} = Instance.register(instance, {:plug, {plug, stacktrace}})

    :ok
  end

  @doc """
  Fetches the generated x509 suite for the current test server.

  ## Examples

      TestServer.HTTP.start(scheme: :https)
      TestServer.HTTP.add("/")

      %{cert: _, cacerts: cacerts} = TestServer.HTTP.x509_suite()
      req_options = [connect_options: [transport_opts: [cacerts: cacerts]]]

      assert {:ok, %Req.Response{status: 200, body: "HTTP/1.1"}} =
              Req.get(TestServer.HTTP.url(), req_options)
  """
  @spec x509_suite() :: x509_suite()
  def x509_suite, do: x509_suite(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Fetches the generated x509 suite for a test server instance.

  See `x509_suite/0` for more.
  """
  @spec x509_suite(TestServer.instance()) :: x509_suite()
  def x509_suite(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    options = Instance.get_options(instance)

    cond do
      not (options[:scheme] == :https) ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} is not running with `[scheme: :https]` option"

      not Keyword.has_key?(options, :x509_suite) ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} is running with custom SSL"

      true ->
        options[:x509_suite]
    end
  end

  @spec websocket_init(binary()) :: {:ok, websocket_socket()}
  def websocket_init(uri) when is_binary(uri), do: websocket_init(uri, [])

  @doc """
  Adds a websocket route to current test server.

  The `:to` option can be overridden the same way as for `add/2`, and will be
  called during the HTTP handshake. If the `conn.state` is `:unset` the
  websocket will be initiated otherwise response is returned as-is.

  ## Options

  Takes the same options as `add/2`, except `:to`.

  ## Examples

      {:ok, socket} = TestServer.HTTP.websocket_init("/ws")
      TestServer.HTTP.websocket_handle(socket)

      assert {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
      assert WebSocketClient.send_message(client, "echo") == {:ok, "echo"}

  `:via` and `:match` are called during the HTTP handshake:

      TestServer.HTTP.websocket_init("/ws", via: :get, match: fn conn ->
        conn.params["token"] == "secret"
      end)

      assert {:ok, _client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws?token=secret"))

  `:to` option is also called during the HTTP handshake:

      TestServer.HTTP.websocket_init("/ws",
        to: fn conn ->
          Plug.Conn.send_resp(conn, 403, "Forbidden")
        end
      )

      assert {:error, %WebSockex.RequestError{code: 403}} =
              WebSocketClient.start_link(TestServer.HTTP.url("/ws"))
  """
  @spec websocket_init(binary(), keyword()) :: {:ok, websocket_socket()}
  def websocket_init(uri, options) when is_binary(uri) do
    {:ok, instance} = TestServer.autostart_instance(__MODULE__)

    websocket_init(instance, uri, options)
  end

  @spec websocket_init(TestServer.instance(), binary()) :: {:ok, websocket_socket()}
  def websocket_init(instance, uri) when is_pid(instance) and is_binary(uri) do
    websocket_init(instance, uri, [])
  end

  @doc """
  Adds a websocket route to a test server.

  See `websocket_init/2` for options.
  """
  @spec websocket_init(TestServer.instance(), binary(), keyword()) :: {:ok, websocket_socket()}
  def websocket_init(instance, uri, options) do
    options =
      options
      |> Keyword.put(:websocket, true)
      |> Keyword.put_new(:to, & &1)

    {:ok, %{ref: ref}} = register_route(instance, uri, options)

    {:ok, {instance, ref}}
  end

  @spec websocket_handle(websocket_socket()) :: :ok
  def websocket_handle(socket), do: websocket_handle(socket, [])

  @doc """
  Adds a message handler to a websocket instance.

  Messages are matched FIFO (first in, first out). Any messages not expected by
  TestServer or any message expectations not receiving a message will raise an
  error in the test case.

  ## Options

    * `:match`     - an `t:websocket_match_fun/0` function that returns a
      boolean. Defaults to matching anything;

    * `:to`        - a `t:websocket_handler_fun/0` function called when the
      handler matches. Defaults to send back the received message;

  ## Examples

      {:ok, socket} = TestServer.HTTP.websocket_init("/ws")

      TestServer.HTTP.websocket_handle(
        socket,
        to: fn _frame, state ->
          {:reply, {:text, "pong"}, state}
        end,
        match: fn frame, _state ->
          frame == {:text, "ping"}
        end)

      TestServer.HTTP.websocket_handle(socket)

      {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

      assert WebSocketClient.send_message(client, "echo") == {:ok, "echo"}
      assert WebSocketClient.send_message(client, "ping") == {:ok, "pong"}
  """
  @spec websocket_handle(websocket_socket(), keyword()) :: :ok
  def websocket_handle({instance, _route_ref} = socket, options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_websocket_handle/2)

    {:ok, _handler} = Instance.register(socket, {:websocket, {:handle, options, stacktrace}})

    :ok
  end

  defp default_websocket_handle(frame, state),
    do: {:reply, frame, state}

  @doc """
  Sends an message to a websocket instance.

  ## Examples

      {:ok, socket} = TestServer.HTTP.websocket_init("/ws")
      {:ok, client} = WebSocketClient.start_link(TestServer.HTTP.url("/ws"))

      assert TestServer.HTTP.websocket_info(socket, fn state ->
        {:reply, {:text, "hello"}, state}
      end) == :ok

      assert WebSocketClient.receive_message(client) == {:ok, "hello"}
  """
  @spec websocket_info(websocket_socket(), websocket_info_fun() | nil) :: :ok
  def websocket_info({instance, _route_ref} = socket, callback \\ nil)
      when is_function(callback) or is_nil(callback) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)

    callback = callback || (&default_websocket_info/1)

    for pid <- Instance.active_websocket_connections(socket) do
      send(pid, {callback, stacktrace})
    end

    :ok
  end

  defp default_websocket_info(state), do: {:reply, {:text, "ping"}, state}
end
