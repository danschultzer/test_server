defmodule TestServer.UDP do
  @external_resource "lib/test_server/udp/README.md"
  @moduledoc "lib/test_server/udp/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  import Kernel, except: [send: 2]

  alias TestServer.UDP.Instance

  @type peer :: {TestServer.instance(), peer_ref()}
  @type peer_ref :: reference()
  @type data :: iodata()
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
  Starts a test server UDP instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`             - integer of port number, defaults to random port
      that can be opened;

    * `:transport`        - the supported socket transport, either `:udp` or
      `:dtls`. Defaults to `:udp`;

    * `:tls`              - passthru options for DTLS configuration handled by
      `:ssl`;

    * `:ipfamily`         - the IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet`;

    * `:listen`           - options passed to the transport listener. Defaults
      to `[mode: :binary]`, `:active` can't be set;

    * `:suppress_warning` - suppresses IO warnings on expectation failures
      related to this instance. Defaults to `false`;

  ## Examples

      TestServer.UDP.handle(to: fn _data, state -> {:reply, "pong", state} end)

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket) == {:ok, "pong"}
  """
  @spec start(keyword()) :: {:ok, TestServer.instance()} | {:error, term()}
  def start(options \\ []) do
    Keyword.validate!(options, [:port, :transport, :tls, :ipfamily, :listen, :suppress_warning])
    TestServer.start_instance(__MODULE__, options, &verify!/1)
  end

  defp verify!(instance) do
    verify_handlers!(instance)
    verify_peers!(instance)
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

  defp verify_peers!(instance) do
    instance
    |> Instance.peers()
    |> Enum.filter(&is_nil(&1.owner))
    |> case do
      [] ->
        :ok

      unused_peers ->
        raise """
        #{TestServer.format_instance(__MODULE__, instance)} has peers that were not used:

        #{Instance.format_peers(unused_peers)}
        """
    end
  end

  @doc """
  Shuts down the current test server UDP instance.

  ## Examples

      _instance = TestServer.UDP.start!()
      address = TestServer.UDP.address()
      :ok = TestServer.UDP.stop()

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, address, "ping") == :ok
      assert {:error, _reason} = UDPClient.receive_data(socket)
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Shuts down a test server UDP instance.
  """
  @spec stop(TestServer.instance()) :: :ok | {:error, term()}
  def stop(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)
    TestServer.stop_instance(__MODULE__, instance)
  end

  @spec address() :: {binary(), :inet.port_number()}
  def address, do: address([])

  @doc """
  Returns the address for the current test server.

  ## Options

    * `:host` - binary host value, it'll be added to inet for IP `127.0.0.1`
      and `::1`, defaults to `"localhost"`;

  ## Examples

      TestServer.UDP.start!(port: 4040)

      assert TestServer.UDP.address() == {"localhost", 4040}
      assert TestServer.UDP.address(host: "myserver.test") == {"myserver.test", 4040}
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

      TestServer.UDP.start!(transport: :dtls)
      TestServer.UDP.handle()

      options = [cacerts: TestServer.UDP.cacerts()]

      assert {:ok, socket} = DTLSClient.connect(TestServer.UDP.address(), options)
      assert DTLSClient.send(socket, "ping") == :ok
      assert DTLSClient.receive_data(socket) == {:ok, "ping"}
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
      options[:transport] != :dtls ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} is not running with `[transport: :dtls]` option"

      not Keyword.has_key?(options, :cacerts) ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} is running with custom `:tls` certificate options"

      true ->
        Keyword.fetch!(options, :cacerts)
    end
  end

  @doc """
  Adds an expected UDP peer on the current test server instance.

  Peers are exhausted FIFO (first in, first out) as clients sends data or
  establishes a DTLS connection.

  ## Examples

      peer_1 = TestServer.UDP.peer()
      peer_2 = TestServer.UDP.peer()

      TestServer.UDP.handle(peer_1, to: fn _data, state -> {:reply, "peer 1", state} end)
      TestServer.UDP.handle(peer_2, to: fn _data, state -> {:reply, "peer 2", state} end)

      assert {:ok, socket_1} = UDPClient.open()
      assert {:ok, socket_2} = UDPClient.open()
      assert UDPClient.send(socket_2, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket_2) == {:ok, "peer 1"}
      assert UDPClient.send(socket_1, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket_1) == {:ok, "peer 2"}
  """
  @spec peer() :: peer()
  def peer do
    instance = TestServer.autostart_instance(__MODULE__)

    peer(instance)
  end

  @doc """
  Adds an expected UDP peer to a test server instance.

  See `peer/0` for behaviour.
  """
  @spec peer(TestServer.instance()) :: peer()
  def peer(instance) when is_pid(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    {:ok, peer} = Instance.register(instance, {:peer, stacktrace})

    {instance, peer.ref}
  end

  def handle, do: handle([])

  @spec handle(peer() | keyword()) :: :ok
  def handle(options) when is_list(options) do
    instance = TestServer.autostart_instance(__MODULE__)

    peer =
      case Instance.peers(instance) do
        [%{ref: peer_ref}] ->
          {instance, peer_ref}

        [] ->
          peer(instance)

        _multiple_peers ->
          raise "Multiple peers available, please pass peer to `TestServer.UDP.handle/2`"
      end

    handle(peer, options)
  end

  def handle(peer), do: handle(peer, [])

  @doc """
  Adds a data handler to the current test server UDP instance.

  Handlers are matched FIFO (first in, first out). Any data not matched by a
  handler, or any handlers not consumed by data, will raise an error in the
  test case.

  The `:to` callback returns `{:reply, data, state}` or `{:ok, state}`.

  ## Options

    * `:match` - a `t:match_fun/0` function that returns a boolean. Defaults
      to matching anything;

    * `:to`    - a `t:handler_fun/0` function called when the handler
      matches. Defaults to echoing the received data;

  ## Examples

      TestServer.UDP.handle(
        match: fn data, _state -> data == "ping" end,
        to: fn _data, state -> {:reply, "pong", state} end
      )

      TestServer.UDP.handle()

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.send(socket, TestServer.UDP.address(), "echo") == :ok
      assert UDPClient.receive_data(socket) == {:ok, "pong"}
      assert UDPClient.receive_data(socket) == {:ok, "echo"}
  """
  @spec handle(peer(), keyword()) :: :ok
  def handle({instance, peer_ref}, options)
      when is_pid(instance) and is_reference(peer_ref) and is_list(options) do
    Keyword.validate!(options, [:match, :to])
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_handler/2)

    {:ok, _handler} = Instance.register(instance, {:handle, peer_ref, options, stacktrace})

    :ok
  end

  defp default_handler(data, state), do: {:reply, data, state}

  @spec send(peer()) :: :ok
  def send(peer), do: send(peer, [])

  @doc """
  Sends data from the current test server UDP instance to a specific peer.

  The `:to` callback receives the peer state and returns `{:reply, data,
  state}` or `{:ok, state}`.

  ## Options

    * `:to` - a `t:send_fun/0` function called with the peer state.
      Defaults to sending `"ping"`.

    * `:timeout` - the maximum time in milliseconds to wait for the peer to
      send data or establish a DTLS connection before sending the data.
      Defaults to `1_000`.

  ## Examples

      peer = TestServer.UDP.peer()
      :ok = TestServer.UDP.handle()

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, TestServer.UDP.address(), "ping") == :ok
      assert UDPClient.receive_data(socket) == {:ok, "ping"}

      TestServer.UDP.send(peer, to: fn state -> {:reply, "hello", state} end)

      assert UDPClient.receive_data(socket) == {:ok, "hello"}
  """
  @spec send(peer(), keyword()) :: :ok
  def send({instance, peer_ref}, options)
      when is_pid(instance) and is_reference(peer_ref) and is_list(options) do
    Keyword.validate!(options, [:to, :timeout])
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_send/1)

    case Instance.register(instance, {:send, peer_ref, options}) do
      {:ok, pid} ->
        Kernel.send(pid, {:send, {options, stacktrace}})

        :ok

      {:error, :einval} ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the peer, because the peer does not exist"

      {:error, :enotconn} ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the peer, because no client has sent a datagram or established a DTLS connection"

      {:error, :closed} ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} cannot send to the peer, because client has disconnected"
    end
  end

  defp default_send(state), do: {:reply, "ping", state}
end
