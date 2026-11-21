defmodule TestServer.UDP do
  @external_resource "lib/test_server/udp/README.md"
  @moduledoc "lib/test_server/udp/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)
             |> String.trim()

  import Kernel, except: [send: 2]

  alias TestServer.UDP.Instance

  @type peer :: {TestServer.instance(), peer_ref()}
  @type peer_ref :: reference()
  @type data :: iodata()
  @type state :: term()

  @typedoc "An anonymous function that matches received data."
  @type match_fun :: (data(), state() -> boolean())

  @typedoc "An anonymous function that processes received data."
  @type handler_fun :: (data(), state() -> {:reply, iodata(), state()} | {:ok, state()})

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
  Starts a test server UDP instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`             - integer of port number. Defaults to `0` which
      selects a random port;

    * `:ip`               - a `t:TestServer.ip_address/0` the server will bind
      to. Defaults to `:loopback`;

    * `:ipfamily`         - the IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet6` if `:ip` is IPv6 format, otherwise
      `:inet`;

    * `:transport`        - the supported socket transport, either `:udp` or
      `:dtls`. Defaults to `:udp`;

    * `:tls`              - passthru options for DTLS configuration handled by
      `:ssl`;

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
        expected #{TestServer.format_instance(instance)} to receive data for these handlers before the test ended:

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
        expected all peers on #{TestServer.format_instance(instance)} to be used, but some were not:

        #{Instance.format_peers(unused_peers)}
        """
    end
  end

  @doc """
  Shuts down the current test server UDP instance.

  Removes the ExUnit test callback which eliminates verification of any
  outstanding expectations.

  ## Examples

      _instance = TestServer.UDP.start!()
      address = TestServer.UDP.address()
      :ok = TestServer.UDP.stop()

      assert {:ok, socket} = UDPClient.open()
      assert UDPClient.send(socket, address, "ping") == :ok
      assert {:error, _reason} = UDPClient.receive_data(socket)
  """
  @spec stop() :: :ok
  def stop, do: stop(TestServer.fetch_protocol_instance!(__MODULE__))

  @doc """
  Shuts down a test server UDP instance.

  See `stop/0` for more.
  """
  @spec stop(TestServer.instance()) :: :ok
  def stop({__MODULE__, _instance_pid} = instance) do
    :ok = TestServer.assert_instance_alive!(instance)
    receiver_pid = instance |> Instance.options() |> Keyword.fetch!(:receiver)
    monitor = Process.monitor(receiver_pid)

    TestServer.stop_instance(instance)

    receive do
      {:DOWN, ^monitor, :process, ^receiver_pid, _reason} -> :ok
    after
      5_000 -> raise "expected UDP receiver #{inspect(receiver_pid)} to shut down"
    end
  end

  @spec address() :: {binary(), TestServer.port_number()}
  def address, do: address([])

  @doc """
  Returns the address for the current test server.

  ## Options

    * `:host` - binary host value, it'll be registered in the `m::inet` DNS
      file for the instance's IP. Defaults to `"localhost"`;

  ## Examples

      TestServer.UDP.start!(port: 4040)

      assert TestServer.UDP.address() == {"localhost", 4040}
      assert TestServer.UDP.address(host: "myhost.test") == {"myhost.test", 4040}
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

      TestServer.UDP.start!(transport: :dtls)
      TestServer.UDP.handle()

      options = [cacerts: TestServer.UDP.cacerts()]

      assert {:ok, socket} = DTLSClient.connect(TestServer.UDP.address(), options)
      assert DTLSClient.send(socket, "ping") == :ok
      assert DTLSClient.receive_data(socket) == {:ok, "ping"}
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
      options[:transport] != :dtls ->
        raise "expected #{TestServer.format_instance(instance)} to be running with [transport: :dtls] option"

      not Keyword.has_key?(options, :cacerts) ->
        raise "expected #{TestServer.format_instance(instance)} not to be running with [tls: [cacerts: ...]] option"

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
  def peer({__MODULE__, _instance_pid} = instance) do
    TestServer.assert_instance_alive!(instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    {:ok, peer} = Instance.register(instance, {:peer, stacktrace})

    {instance, peer.ref}
  end

  def handle, do: handle([])

  @doc """
  Adds a data handler to the current test server UDP peer.

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
  @spec handle(keyword()) :: :ok
  def handle(options) when is_list(options) do
    instance = TestServer.autostart_instance(__MODULE__)

    peer =
      case Instance.peers(instance) do
        [%{ref: peer_ref}] ->
          {instance, peer_ref}

        [] ->
          peer(instance)

        _multiple_peers ->
          raise "expected exactly one peer to be available, but got multiple peers; pass the peer to TestServer.UDP.handle/2"
      end

    handle(peer, options)
  end

  @spec handle(peer()) :: :ok
  def handle(peer), do: handle(peer, [])

  @doc """
  Adds a data handler to a test server UDP peer.

  See `handle/1` for options.
  """
  @spec handle(peer(), keyword()) :: :ok
  def handle({{__MODULE__, _instance_pid} = instance, peer_ref} = _peer, options)
      when is_list(options) do
    Keyword.validate!(options, [:match, :to])
    TestServer.assert_instance_alive!(instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)
    options = Keyword.put_new(options, :to, &default_handler/2)

    {:ok, _handler} = Instance.register(instance, {:handle, peer_ref, options, stacktrace})

    :ok
  end

  defp default_handler(data, state), do: {:reply, data, state}

  @spec send(peer()) :: :ok
  def send(peer), do: send(peer, [])

  @doc """
  Sends data to a test server UDP peer.

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
  def send({{__MODULE__, _instance_pid} = instance, peer_ref} = _peer, options)
      when is_list(options) do
    Keyword.validate!(options, [:to, :timeout])
    TestServer.assert_instance_alive!(instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)
    options = Keyword.put_new(options, :to, &default_send/1)

    case Instance.register(instance, {:send, peer_ref, options}) do
      {:ok, owner_pid} ->
        Kernel.send(owner_pid, {:send, {options, stacktrace}})

        :ok

      {:error, :einval} ->
        raise_send_error!(instance, "it does not exist")

      {:error, :enotconn} ->
        raise_send_error!(
          instance,
          "no client has sent a datagram or established a DTLS connection"
        )

      {:error, :closed} ->
        raise_send_error!(instance, "the client has disconnected")
    end
  end

  defp default_send(state), do: {:reply, "ping", state}

  defp raise_send_error!(instance, reason) do
    raise "cannot send to peer on #{TestServer.format_instance(instance)} because #{reason}"
  end
end
