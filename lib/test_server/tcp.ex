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
  @type data :: term()
  @type state :: term()
  @type handler_fun :: (data(), state() ->
                          {:reply, iodata(), state()}
                          | {:ok, state()})
  @type match_fun :: (data(), state() -> boolean())
  @type send_fun :: (state() ->
                       {:reply, iodata(), state()}
                       | {:ok, state()})

  @doc """
  Same as `start/1`, but returns the instance and raises on failure.
  """
  @spec start!(keyword()) :: TestServer.instance()
  def start!(options \\ []) do
    case start(options) do
      {:ok, instance} -> instance
      {:error, reason} -> TestServer.raise_start_failure!(__MODULE__, options, reason)
    end
  end

  @doc """
  Start a test server TCP instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`             - integer of port number, defaults to random port
      that can be opened;

    * `:ipfamily`         - The IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet`;

    * `:listen`           - options passed to `:gen_tcp.listen/2`. Defaults to
      `[:binary]`, `:active` can't be set;

    * `:suppress_warning` - Suppresses IO warnings on expectation failures
      related to this instance. Defaults to `false`;

  ## Examples

      TestServer.TCP.start!(
        listen: [packet: :line]
      )

      TestServer.TCP.handle(to: fn _data, state -> {:reply, "pong\\r\\n", state} end)

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping\\r\\n") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "pong\\r\\n"}
  """
  @spec start(keyword()) :: {:ok, TestServer.instance()} | {:error, term()}
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
    |> Enum.filter(&is_nil(&1.owner))
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

      _instance = TestServer.TCP.start!()
      address = TestServer.TCP.address()
      :ok = TestServer.TCP.stop()

      assert TCPClient.connect(address) ==
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

    :ok = Server.stop(Instance.options(instance), Instance.connections(instance))

    TestServer.stop_instance(__MODULE__, instance)
  end

  @spec address() :: {binary(), :inet.port_number()}
  def address, do: address([])

  @doc """
  Returns the address for current test server.

  ## Options

    * `:host` - binary host value, it'll be added to inet for IP `127.0.0.1`
      and `::1`, defaults to `"localhost"`;

  ## Examples

      TestServer.TCP.start!(port: 4040)

      assert TestServer.TCP.address() == {"localhost", 4040}
      assert TestServer.TCP.address(host: "myserver.test") == {"myserver.test", 4040}
  """
  @spec address(keyword() | TestServer.instance()) :: {binary(), :inet.port_number()}
  def address(options) when is_list(options),
    do: address(TestServer.fetch_instance!(__MODULE__), options)

  def address(instance) when is_pid(instance), do: address(instance, [])

  @doc """
  Returns the address for a test server instance.

  See `address/1` for options.
  """
  @spec address(TestServer.instance(), keyword()) :: {binary(), :inet.port_number()}
  def address(instance, options) when is_pid(instance) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    host = TestServer.host(options)
    port = instance |> Instance.options() |> Keyword.fetch!(:port)

    {host, port}
  end

  @doc """
  Adds an expected TCP connection on the current test server instance.

  Connections are exhausted FIFO (first in, first out) as sockets are opened.

  ## Examples

      connection_1 = TestServer.TCP.connection()
      connection_2 = TestServer.TCP.connection()

      TestServer.TCP.handle(connection_1, to: fn _, state -> {:reply, "connection 1", state} end)
      TestServer.TCP.handle(connection_2, to: fn _, state -> {:reply, "connection 2", state} end)

      assert {:ok, socket_1} = TCPClient.connect(TestServer.TCP.address())
      assert {:ok, socket_2} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket_2, "ping") == {:ok, "connection 2"}
      assert TCPClient.send(socket_1, "ping") == {:ok, "connection 1"}
  """
  @spec connection() :: connection()
  def connection do
    instance = TestServer.autostart_instance(__MODULE__)

    connection(instance)
  end

  @doc """
  Adds an expected TCP connection to a test server instance.

  See `connection/1` for behaviour.
  """
  @spec connection(TestServer.instance()) :: connection()
  def connection(instance) when is_pid(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    {:ok, connection} = Instance.register(instance, {:connection, stacktrace})

    {instance, connection.ref}
  end

  def handle, do: handle([])

  @spec handle(connection() | keyword()) :: :ok
  def handle(options) when is_list(options) do
    instance = TestServer.autostart_instance(__MODULE__)

    connection =
      case Instance.connections(instance) do
        [%{ref: connection_ref}] ->
          {instance, connection_ref}

        [] ->
          connection(instance)

        _multiple_connections ->
          raise "Multiple connections available, please pass connection to `TestServer.TCP.handle/2`"
      end

    handle(connection, options)
  end

  def handle(connection), do: handle(connection, [])

  @doc """
  Adds a data handler to the current test server TCP instance.

  Handlers are matched FIFO (first in, first out). Any data not matched by a
  handler, or any handlers not consumed by data, will raise an error in the
  test case.

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

      TestServer.TCP.handle(
        match: fn data, _state -> data == "ping" end,
        to: fn _data, state -> {:reply, "pong", state} end
      )

      TestServer.TCP.handle()

      {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

      assert TCPClient.send(socket, "ping") == {:ok, "pong"}
      assert TCPClient.send(socket, "echo") == {:ok, "echo"}
  """
  @spec handle(connection(), keyword()) :: :ok
  def handle({instance, connection_ref}, options)
      when is_pid(instance) and is_reference(connection_ref) and is_list(options) do
    register_handler(instance, connection_ref, options)
  end

  defp register_handler(instance, connection_ref, options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_handler/2)

    {:ok, _handler} =
      Instance.register(instance, {:handle, {connection_ref, options, stacktrace}})

    :ok
  end

  defp default_handler(data, state), do: {:reply, data, state}

  @spec send(connection()) :: :ok
  def send(connection), do: send(connection, [])

  @doc """
  Sends data from the current test server TCP instance to a specific
  connection.

  The `:to` callback receives the connection state and returns
  `{:reply, data, state}` or `{:ok, state}`. For reply tuples, the framework
  calls `:gen_tcp.send/2` for you.

  The `:to` callback runs inside the test server instance process, so it must
  not call back into the `TestServer.TCP` API for the same instance.

  ## Options

    * `:to` - a `t:send_fun/0` function called with the connection state.
      Defaults to sending `"ping"`.

  ## Examples

      connection = TestServer.TCP.connection()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

      TestServer.TCP.send(connection, to: fn state -> {:reply, "hello", state} end)

      assert TCPClient.receive_data(socket) == {:ok, "hello"}
  """
  @spec send(connection(), keyword()) :: :ok
  def send({instance, connection_ref} = connection, options)
      when is_pid(instance) and is_reference(connection_ref) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_send/1)

    connection
    |> Instance.dispatch({:send, options, stacktrace})
    |> handle_send_response(instance)
  end

  defp default_send(state), do: {:reply, "ping", state}

  defp handle_send_response(:ok, _instance), do: :ok

  defp handle_send_response({:error, :einval}, instance) do
    raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the connection, because the connection does not exist"
  end

  defp handle_send_response({:error, :enotconn}, instance) do
    raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the connection, because no client has connected to it"
  end

  defp handle_send_response({:error, :closed}, instance) do
    raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the connection, because client has disconnected"
  end

  defp handle_send_response({:error, {exception, stacktrace}}, instance) do
    TestServer.report_error(Instance.options(instance), {exception, stacktrace})

    :ok
  end

  defp handle_send_response({:error, reason}, instance) do
    raise "#{TestServer.format_instance(__MODULE__, instance)} could not send data to the connection, because: #{inspect(reason)}"
  end
end
