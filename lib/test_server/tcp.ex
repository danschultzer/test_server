defmodule TestServer.TCP do
  @external_resource "lib/test_server/tcp/README.md"
  @moduledoc "lib/test_server/tcp/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  import Kernel, except: [send: 2]

  alias TestServer.TCP.{Instance, Server}

  @type connection :: {TestServer.instance(), connection_ref()}
  @type connection_ref :: reference()
  @type data :: binary()
  @type state :: term()
  @type handler_fun :: (data(), state() ->
                          {:reply, iodata(), state()}
                          | {:ok, state()})
  @type match_fun :: (data(), state() -> boolean())
  @type send_fun :: (state() ->
                       {:reply, iodata(), state()}
                       | {:ok, state()})

  @doc """
  Start a test server TCP instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`           - integer of port number, defaults to random port
      that can be opened;

    * `:ipfamily`       - The IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet`;

    * `:listen_options` - options passed to `:gen_tcp.listen/2`. Defaults to
      `[:binary, active: false, reuseaddr: true]`. `active: false` is always
      used by the server;

    * `:suppress_warning` - Suppresses IO warnings on expectation failures
      related to this instance. Defaults to `false`;

  ## Examples

      {:ok, _instance} = TestServer.TCP.start(
        listen_options: [:binary, packet: :line]
      )

      :ok =
        TestServer.TCP.handle(
          match: fn data, _state -> data == "PING\\n" end,
          to: fn _data, state -> {:reply, "PONG\\n", state} end
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", elem(TestServer.TCP.address(), 1), [
          :binary,
          active: false,
          packet: :line
        ])

      :ok = :gen_tcp.send(socket, "PING\\n")
      assert {:ok, "PONG\\n"} = :gen_tcp.recv(socket, 0)
  """
  @spec start(keyword()) :: {:ok, TestServer.instance()}
  def start(options \\ []) do
    TestServer.start_instance(__MODULE__, options, &verify!/1)
  end

  defp verify!(instance) do
    verify_handlers!(instance)
    verify_connections!(instance)
  end

  defp verify_handlers!(instance) do
    instance
    |> Instance.handlers()
    |> Enum.reject(& &1.suspended)
    |> case do
      [] ->
        :ok

      active_handlers ->
        raise """
        #{TestServer.format_instance(__MODULE__, instance)} did not receive data for these handlers before the test ended:

        #{Instance.format_handlers(active_handlers)}
        """
    end
  end

  defp verify_connections!(instance) do
    instance
    |> Instance.connections()
    |> Enum.filter(&(not is_nil(&1.ref) and is_nil(&1.pid)))
    |> case do
      [] ->
        :ok

      unused_connections ->
        raise """
        #{TestServer.format_instance(__MODULE__, instance)} has connections that were not used:

        #{Instance.format_connections(unused_connections)}
        """
    end
  end

  @doc """
  Shuts down the current test server TCP instance.

  ## Examples

      {:ok, _instance} = TestServer.TCP.start()
      {host, port} = TestServer.TCP.address()
      :ok = TestServer.TCP.stop()

      assert :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false]) ==
               {:error, :econnrefused}
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Shuts down a test server TCP instance.
  """
  @spec stop(TestServer.instance()) :: :ok | {:error, term()}
  def stop(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    :ok = Server.stop(Instance.get_options(instance), Instance.connections(instance))

    TestServer.stop_instance(__MODULE__, instance)
  end

  @spec address() :: {binary(), non_neg_integer()}
  def address, do: address([])

  @doc """
  Returns the address for current test server.

  ## Options

    * `:host` - binary host value, it'll be added to inet for IP `127.0.0.1`
      and `::1`, defaults to `"localhost"`;

  ## Examples

      {:ok, _instance} = TestServer.TCP.start(port: 4040)

      assert TestServer.TCP.address() == {"localhost", 4040}
      assert TestServer.TCP.address(host: "myserver.test") == {"myserver.test", 4040}
  """
  @spec address(keyword() | TestServer.instance()) :: {binary(), non_neg_integer()}
  def address(options) when is_list(options),
    do: address(TestServer.fetch_instance!(__MODULE__), options)

  def address(instance) when is_pid(instance), do: address(instance, [])

  @doc """
  Returns the address for a test server instance.

  See `address/1` for options.
  """
  @spec address(TestServer.instance(), keyword()) :: {binary(), non_neg_integer()}
  def address(instance, options) when is_pid(instance) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    host = TestServer.get_host(options)
    port = instance |> Instance.get_options() |> Keyword.fetch!(:port)

    {host, port}
  end

  @spec connect() :: {:ok, connection()}
  def connect, do: connect([])

  @doc """
  Registers a connection on the current test server TCP instance.

  Connections are bound to incoming TCP sockets FIFO in registration order:
  the first registered connection ref is bound to the first accepted socket,
  the second to the second, and so on. If a socket is accepted while no
  connection ref is waiting, the framework still accepts it as an anonymous
  connection that only matches global handlers (handlers registered without
  a connection ref).

  ## Examples

      {:ok, conn} = TestServer.TCP.connect()

      :ok =
        TestServer.TCP.handle(conn,
          to: fn _data, state -> {:reply, "scoped", state} end
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", elem(TestServer.TCP.address(), 1), [
          :binary,
          active: false
        ])

      :ok = :gen_tcp.send(socket, "ping")
      assert {:ok, "scoped"} = :gen_tcp.recv(socket, 0)
  """
  @spec connect(keyword()) :: {:ok, connection()}
  def connect(options) when is_list(options) do
    {:ok, instance} = TestServer.autostart_instance(__MODULE__)

    connect(instance, options)
  end

  def connect(instance) when is_pid(instance), do: connect(instance, [])

  @doc """
  Registers a connection on a test server TCP instance.

  See `connect/1` for behaviour.
  """
  @spec connect(TestServer.instance(), keyword()) :: {:ok, connection()}
  def connect(instance, options) when is_pid(instance) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)

    {:ok, connection} = Instance.register(instance, {:connect, {options, stacktrace}})

    {:ok, {instance, connection.ref}}
  end

  @spec handle() :: :ok
  def handle, do: handle([])

  @doc """
  Adds a data handler to the current test server TCP instance.

  Handlers are matched FIFO (first in, first out). Any data not matched by a
  handler, or any handlers not consumed by data, will raise an error in the
  test case.

  A handler registered without a connection (`handle/0` or `handle/1` with
  options) is *global* — it matches data on any connection. A handler
  registered with a connection (`handle/2` with a `t:connection/0`) is
  scoped — it only matches data on that connection.

  The `:to` callback returns `{:reply, data, state}` or `{:ok, state}`. For
  reply tuples, the framework calls `:gen_tcp.send/2` for you.

  The `:match` and `:to` callbacks run inside the test server instance
  process, so they must not call back into the `TestServer.TCP` API for the
  same instance.

  ## Options

    * `:match` - a `t:match_fun/0` function that returns a boolean. Defaults
      to matching anything;

    * `:to`    - a `t:handler_fun/0` function called when the handler
      matches. Defaults to echoing the received data.

  ## Examples

      :ok =
        TestServer.TCP.handle(
          match: fn data, _state -> data == "PING" end,
          to: fn _data, state -> {:reply, "PONG", state} end
        )

      :ok = TestServer.TCP.handle()

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", elem(TestServer.TCP.address(), 1), [
          :binary,
          active: false
        ])

      assert :ok = :gen_tcp.send(socket, "PING")
      assert {:ok, "PONG"} = :gen_tcp.recv(socket, 0)
      assert :ok = :gen_tcp.send(socket, "echo")
      assert {:ok, "echo"} = :gen_tcp.recv(socket, 0)
  """
  @spec handle(keyword() | TestServer.instance() | connection()) :: :ok
  def handle(options) when is_list(options) do
    {:ok, instance} = TestServer.autostart_instance(__MODULE__)

    handle(instance, options)
  end

  def handle(instance) when is_pid(instance), do: handle(instance, [])

  def handle({instance, _connection_ref} = connection) when is_pid(instance),
    do: handle(connection, [])

  @doc """
  Adds a data handler to a test server TCP instance or connection.

  See `handle/1` for options. When the first argument is a `t:connection/0`
  the handler is scoped to that connection; otherwise it is global.
  """
  @spec handle(TestServer.instance() | connection(), keyword()) :: :ok
  def handle(instance, options) when is_pid(instance) and is_list(options) do
    register_handler(instance, nil, options)
  end

  def handle({instance, connection_ref}, options)
      when is_pid(instance) and is_reference(connection_ref) and is_list(options) do
    register_handler(instance, connection_ref, options)
  end

  defp register_handler(instance, connection_ref, options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_handler/2)

    {:ok, _handler} =
      Instance.register(instance, {:handle, {connection_ref, options, stacktrace}})

    :ok
  end

  defp default_handler(data, state), do: {:reply, data, state}

  @spec send(connection()) :: :ok
  def send({instance, _connection_ref} = connection) when is_pid(instance),
    do: send(connection, [])

  @doc """
  Sends data from the current test server TCP instance to a specific
  connection.

  The `:to` callback receives the connection state and returns
  `{:reply, data, state}` or `{:ok, state}`. For reply tuples, the framework
  calls `:gen_tcp.send/2` for you. Raises if the client has disconnected.

  The `:to` callback runs inside the test server instance process, so it must
  not call back into the `TestServer.TCP` API for the same instance.

  ## Options

    * `:to` - a `t:send_fun/0` function called with the connection state.
      Defaults to sending `"ping"`.

  ## Examples

      {:ok, conn} = TestServer.TCP.connect()

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", elem(TestServer.TCP.address(), 1), [
          :binary,
          active: false
        ])

      :ok = TestServer.TCP.send(conn, to: fn state -> {:reply, "hello", state} end)
      assert {:ok, "hello"} = :gen_tcp.recv(socket, 0)
  """
  @spec send(connection(), keyword()) :: :ok
  def send({instance, connection_ref}, options)
      when is_pid(instance) and is_reference(connection_ref) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_send/1)

    instance
    |> Instance.dispatch({:send, {connection_ref, options, stacktrace}})
    |> handle_send_response(instance)
  end

  defp default_send(state), do: {:reply, "ping", state}

  defp handle_send_response({:send, socket, data}, instance) do
    case Server.send(socket, data) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} could not send data to the connection, because: #{inspect(reason)}"
    end
  end

  defp handle_send_response(:ok, _instance), do: :ok

  defp handle_send_response({:error, :not_found}, instance) do
    raise "#{TestServer.format_instance(__MODULE__, instance)} has no connection registered with the given ref"
  end

  defp handle_send_response({:error, :not_connected}, instance) do
    raise "#{TestServer.format_instance(__MODULE__, instance)} has a connection registered but no client has connected to it yet"
  end

  defp handle_send_response({:error, {exception, stacktrace}, socket}, instance) do
    Instance.report_error(instance, {exception, stacktrace})
    Server.send(socket, Exception.format(:error, exception, stacktrace))
    :ok
  end
end
