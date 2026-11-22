defmodule TestServer.TCP do
  @external_resource "lib/test_server/tcp/README.md"
  @moduledoc "lib/test_server/tcp/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)
             |> String.trim()

  import Kernel, except: [send: 2]

  alias TestServer.TCP.Instance

  @type connection :: {TestServer.instance(), connection_ref()}
  @type connection_ref :: reference()
  @type data :: iodata()
  @type state :: term()

  @typedoc "An anonymous function that matches received data."
  @type match_fun :: (data(), state() -> boolean())

  @typedoc "An anonymous function that processes received data."
  @type handler_fun :: (data(), state() ->
                          {:reply, iodata(), state()}
                          | {:reply, {iodata(), reply_options()}, state()}
                          | {:ok, state()})

  @typedoc "Options for the `{:reply, {data, options}, state}` return of a `t:handler_fun/0`."
  @type reply_options :: [upgrade: :tls]

  @typedoc "An anonymous function that sends data."
  @type send_fun :: (state() -> {:reply, iodata(), state()} | {:ok, state()})

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
  Starts a test server TCP instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`             - integer of port number. Defaults to `0` which
      selects a random port;

    * `:ip`               - a `t:TestServer.ip_address/0` the server will bind
      to. Defaults to `:loopback`;

    * `:ipfamily`         - the IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet6` if `:ip` is IPv6 format, otherwise
      `:inet`;

    * `:transport`        - the supported socket transport, either `:tcp`,
      `:tls`, or a list containing both. Defaults to `:tcp`;

    * `:tls`              - passthru options for TLS configuration handled by
      `:ssl`;

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
    Keyword.validate!(options, [
      :port,
      :ip,
      :transport,
      :tls,
      :ipfamily,
      :listen,
      :suppress_warning
    ])

    TestServer.start_instance(__MODULE__, options, &verify_instance!/1)
  end

  defp verify_instance!(instance) do
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
        expected #{TestServer.format_instance(instance)} to receive data for these handlers before the test ended:

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
        expected all connections on #{TestServer.format_instance(instance)} to be used, but some were not:

        #{Instance.format_connections(unused_connections)}
        """
    end
  end

  @doc """
  Shuts down the current test server TCP instance.

  Removes the ExUnit test callback which eliminates verification of any
  outstanding expectations.

  ## Examples

      _instance = TestServer.TCP.start!()
      address = TestServer.TCP.address()
      :ok = TestServer.TCP.stop()

      assert {:error, _reason} = TCPClient.connect(address)
  """
  @spec stop() :: :ok
  def stop, do: stop(TestServer.fetch_protocol_instance!(__MODULE__))

  @doc """
  Shuts down a test server TCP instance.

  See `stop/0` for more.
  """
  @spec stop(TestServer.instance()) :: :ok
  def stop({__MODULE__, _instance_pid} = instance) do
    :ok = TestServer.assert_instance_alive!(instance)
    acceptor_pid = instance |> Instance.options() |> Keyword.fetch!(:acceptor)
    monitor = Process.monitor(acceptor_pid)

    TestServer.stop_instance(instance)

    receive do
      {:DOWN, ^monitor, :process, ^acceptor_pid, _reason} -> :ok
    after
      5_000 -> raise "expected TCP acceptor #{inspect(acceptor_pid)} to shut down"
    end
  end

  @spec address() :: {binary(), TestServer.port_number()}
  def address, do: address([])

  @doc """
  Returns the address for current test server.

  ## Options

    * `:host` - binary host value, it'll be registered in the `m::inet` DNS
      file for the instance's IP. Defaults to `"localhost"`;

  ## Examples

      TestServer.TCP.start!(port: 4040)

      assert TestServer.TCP.address() == {"localhost", 4040}
      assert TestServer.TCP.address(host: "myhost.test") == {"myhost.test", 4040}
  """
  @spec address(keyword() | TestServer.instance()) :: {binary(), TestServer.port_number()}
  def address(options) when is_list(options),
    do: address(TestServer.fetch_protocol_instance!(__MODULE__), options)

  def address({__MODULE__, _instance_pid} = instance), do: address(instance, [])

  @doc """
  Returns the address for a test server instance.

  See `address/1` for options.
  """
  @spec address(TestServer.instance(), keyword()) :: {binary(), TestServer.port_number()}
  def address({__MODULE__, _instance_pid} = instance, options) when is_list(options) do
    TestServer.assert_instance_alive!(instance)

    options =
      instance
      |> Instance.options()
      |> Keyword.take(~w(port ip ipfamily)a)
      |> Keyword.merge(options)

    port = Keyword.fetch!(options, :port)
    host = TestServer.add_host(options)

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
  def cacerts, do: cacerts(TestServer.fetch_protocol_instance!(__MODULE__))

  @doc """
  Fetches the generated CA certificates for a test server instance.

  See `cacerts/0` for more.
  """
  @spec cacerts(TestServer.instance()) :: TestServer.cacerts()
  def cacerts({__MODULE__, _instance_pid} = instance) do
    TestServer.assert_instance_alive!(instance)

    options = Instance.options(instance)

    cond do
      :tls not in options[:transport] ->
        raise "expected #{TestServer.format_instance(instance)} to be running with [transport: :tls] or [transport: [:tcp, :tls]] options"

      not Keyword.has_key?(options, :cacerts) ->
        raise "expected #{TestServer.format_instance(instance)} not to be running with [tls: [cacerts: ...]] option"

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
  def connection({__MODULE__, _instance_pid} = instance) do
    TestServer.assert_instance_alive!(instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    {:ok, connection} = Instance.register(instance, {:connection, stacktrace})

    {instance, connection.ref}
  end

  def handle, do: handle([])

  @doc """
  Adds a data handler to the current test server TCP connection.

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
  @spec handle(keyword()) :: :ok
  def handle(options) when is_list(options) do
    instance = TestServer.autostart_instance(__MODULE__)

    connection =
      case Instance.connections(instance) do
        [%{ref: connection_ref}] ->
          {instance, connection_ref}

        [] ->
          connection(instance)

        _multiple_connections ->
          raise "expected exactly one connection to be available, but got multiple connections; pass the connection to TestServer.TCP.handle/2"
      end

    handle(connection, options)
  end

  @spec handle(connection()) :: :ok
  def handle(connection), do: handle(connection, [])

  @doc """
  Adds a data handler to a test server TCP connection.

  See `handle/1` for options.
  """
  @spec handle(connection(), keyword()) :: :ok
  def handle({{__MODULE__, _instance_pid} = instance, connection_ref} = _connection, options)
      when is_list(options) do
    Keyword.validate!(options, [:match, :to])
    TestServer.assert_instance_alive!(instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)
    options = Keyword.put_new(options, :to, &default_handler/2)

    case Instance.register(instance, {:handle, connection_ref, options, stacktrace}) do
      {:ok, _handler} -> :ok
      {:error, :not_found} -> raise_connection_not_found!(instance, connection_ref)
    end
  end

  defp default_handler(data, state), do: {:reply, data, state}

  defp raise_connection_not_found!(instance, connection_ref) do
    raise "expected #{TestServer.format_instance(instance)} to have a connection registered under #{inspect(connection_ref)}"
  end

  @spec send(connection()) :: :ok
  def send(connection), do: send(connection, [])

  @doc """
  Sends data to a test server TCP connection.

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
  def send({{__MODULE__, _instance_pid} = instance, connection_ref} = _connection, options)
      when is_list(options) do
    Keyword.validate!(options, [:to, :timeout])
    TestServer.assert_instance_alive!(instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)
    options = Keyword.put_new(options, :to, &default_send/1)

    case Instance.register(instance, {:send, connection_ref, options}) do
      {:ok, owner_pid} ->
        Kernel.send(owner_pid, {:send, {options, stacktrace}})

        :ok

      {:error, :not_found} ->
        raise_connection_not_found!(instance, connection_ref)

      {:error, :enotconn} ->
        raise_send_error!(instance, "no client has connected to it")

      {:error, :closed} ->
        raise_send_error!(instance, "the client has disconnected")
    end
  end

  defp default_send(state), do: {:reply, "ping", state}

  defp raise_send_error!(instance, reason) do
    raise "cannot send to connection on #{TestServer.format_instance(instance)} because #{reason}"
  end
end
