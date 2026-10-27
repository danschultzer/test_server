defmodule TestServer.TCP do
  @external_resource "lib/test_server/tcp/README.md"
  @moduledoc "lib/test_server/tcp/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  import Kernel, except: [send: 2]

  alias TestServer.TCP.Instance

  @type connection :: {TestServer.instance(), connection_ref()}
  @type connection_ref :: reference()
  @type data :: iodata()
  @type state :: term()
  @type reply_options :: [upgrade: :tls]
  @type handler_fun :: (data(), state() ->
                          {:reply, iodata(), state()}
                          | {:reply, {iodata(), reply_options()}, state()}
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

    * `:transport`        - the supported socket transport, either `:tcp`,
      `:tls`, or a list containing both. Defaults to `:tcp`;

    * `:tls`              - passthru options for TLS configuration handled by
      `:ssl`;

    * `:ipfamily`         - the IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet`;

    * `:listen`           - options passed to the transport listener. Defaults
      to `[mode: :binary]`, `:active` can't be set;

    * `:suppress_warning` - suppresses IO warnings on expectation failures
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
    Keyword.validate!(options, [:port, :transport, :tls, :ipfamily, :listen, :suppress_warning])
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

      assert {:error, _reason} = TCPClient.connect(address)
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Shuts down a test server TCP instance.
  """
  @spec stop(TestServer.instance()) :: :ok | {:error, term()}
  def stop(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)
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
    Keyword.validate!(options, [:host])
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    host = TestServer.host(options)
    port = instance |> Instance.options() |> Keyword.fetch!(:port)

    {host, port}
  end

  @doc """
  Fetches the generated CA certificates for the current test server.

  ## Examples

      TestServer.TCP.start!(transport: :tls)
      TestServer.TCP.handle()

      options = [cacerts: TestServer.TCP.cacerts()]

      assert {:ok, socket} = TLSClient.connect(TestServer.TCP.address(), options)
      assert TLSClient.send(socket, "ping\\r\\n") == :ok
      assert TLSClient.receive_data(socket) == {:ok, "ping\\r\\n"}
  """
  @spec cacerts() :: TestServer.cacerts()
  def cacerts, do: cacerts(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Fetches the generated CA certificates for a test server instance.

  See `cacerts/0` for more.
  """
  @spec cacerts(TestServer.instance()) :: TestServer.cacerts()
  def cacerts(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    options = Instance.options(instance)

    cond do
      :tls not in options[:transport] ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} is not running with `[transport: :tls]` or `[transport: [:tcp, :tls]]` options"

      not Keyword.has_key?(options, :cacerts) ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} is running with custom `:tls` certificate options"

      true ->
        Keyword.fetch!(options, :cacerts)
    end
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
      assert TCPClient.send(socket_2, "ping") == :ok
      assert TCPClient.send(socket_1, "ping") == :ok
      assert TCPClient.receive_data(socket_1) == {:ok, "connection 1"}
      assert TCPClient.receive_data(socket_2) == {:ok, "connection 2"}
  """
  @spec connection() :: connection()
  def connection do
    instance = TestServer.autostart_instance(__MODULE__)

    connection(instance)
  end

  @doc """
  Adds an expected TCP connection to a test server instance.

  See `connection/0` for behaviour.
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

  The `:to` callback returns `{:reply, data, state}`, `{:reply, {data, options},
  state}`, or `{:ok, state}`. Set `upgrade: :tls` in the reply options to send
  the reply over the plain connection and then upgrade that connection to TLS.

  ## Options

    * `:match` - a `t:match_fun/0` function that returns a boolean. Defaults
      to matching anything;

    * `:to`    - a `t:handler_fun/0` function called when the handler
      matches. Defaults to echoing the received data;

  ## `:to` return options

  The `{:reply, {data, options}, state}` return from a `t:handler_fun/0` allows
  you to specify options in the options keyword list:

    * `upgrade: :tls` - upgrades the connection to TLS after sending reply;

  ## Examples

      TestServer.TCP.handle(
        match: fn data, _state -> data == "ping" end,
        to: fn _data, state -> {:reply, "pong", state} end
      )

      TestServer.TCP.handle()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())
      assert TCPClient.send(socket, "ping") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "pong"}
      assert TCPClient.send(socket, "echo") == :ok
      assert TCPClient.receive_data(socket) == {:ok, "echo"}
  """
  @spec handle(connection(), keyword()) :: :ok
  def handle({instance, connection_ref}, options)
      when is_pid(instance) and is_reference(connection_ref) and is_list(options) do
    Keyword.validate!(options, [:match, :to])
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_handler/2)

    {:ok, _handler} = Instance.register(instance, {:handle, connection_ref, options, stacktrace})

    :ok
  end

  defp default_handler(data, state), do: {:reply, data, state}

  @spec send(connection()) :: :ok
  def send(connection), do: send(connection, [])

  @doc """
  Sends data from the current test server TCP instance to a specific
  connection.

  The `:to` callback receives the connection state and returns
  `{:reply, data, state}` or `{:ok, state}`.

  ## Options

    * `:to` - a `t:send_fun/0` function called with the connection state.
      Defaults to sending `"ping"`.

    * `:timeout` - the maximum time in milliseconds to wait for the connection
      to be accepted before sending the data. Defaults to `1_000`.

  ## Examples

      connection = TestServer.TCP.connection()

      assert {:ok, socket} = TCPClient.connect(TestServer.TCP.address())

      TestServer.TCP.send(connection, to: fn state -> {:reply, "hello", state} end)

      assert TCPClient.receive_data(socket) == {:ok, "hello"}
  """
  @spec send(connection(), keyword()) :: :ok
  def send({instance, connection_ref}, options)
      when is_pid(instance) and is_reference(connection_ref) and is_list(options) do
    Keyword.validate!(options, [:to, :timeout])
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_send/1)

    case Instance.register(instance, {:send, connection_ref, options}) do
      {:ok, pid} ->
        Kernel.send(pid, {:send, {options, stacktrace}})

        :ok

      {:error, :einval} ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the connection, because the connection does not exist"

      {:error, :enotconn} ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the connection, because no client has connected to it"

      {:error, :closed} ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the connection, because client has disconnected"
    end
  end

  defp default_send(state), do: {:reply, "ping", state}
end
