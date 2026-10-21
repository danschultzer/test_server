defmodule TestServer.SSH do
  @external_resource "lib/test_server/ssh/README.md"
  @moduledoc "lib/test_server/ssh/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias TestServer.SSH.{Instance, Server}

  @type channel :: {TestServer.instance(), channel_ref()}
  @type channel_ref :: reference()
  @type state :: term()

  @type handler_fun :: (:ssh_connection.channel_msg(), state() ->
                          {:reply, iodata(), state()}
                          | {:reply, {iodata(), keyword()}, state()}
                          | {:ok, state()})

  @type raw_handler_fun :: (:ssh_connection.channel_msg(), :ssh.connection_ref(), state() ->
                              {:ok, state()}
                              | {:stop, :ssh.channel_id(), state()})

  @type match_fun :: (:ssh_connection.channel_msg(), state() -> boolean())

  @type host_key :: %{
          key:
            :public_key.rsa_private_key()
            | :public_key.eddsa_private_key()
            | :public_key.ecdsa_private_key(),
          algorithms: [:ssh.pubkey_alg()],
          fingerprint: binary()
        }

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
  Start a test server SSH instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`             - integer of port number, defaults to random port
      that can be opened;

    * `:host_keys`        - list of host keys, or a
      `c::ssh_server_key_api.host_key/2` function. Default will autogenerate
      keys for algorithms specified in `t::ssh.pubkey_alg/0` and they can be
      fetched from `host_keys/1`;

    * `:auth_keys`        - list of `{"user", public_key}` tuples, or a
      `c::ssh_server_key_api.is_auth_key/3` function. Defaults to an empty
      list.

    * `:user_passwords`   - list of `{"user", "password"}` tuples;

    * `:no_auth_needed`   - boolean value indicating whether to allow
      connections with no authentication. Defaults to `true` if `:auth_keys`
      and `:user_passwords` has not been set, otherwise `false`;

    * `:ipfamily`         - The IP address type to use, either `:inet` or
      `:inet6`. Defaults to `:inet`;

    * `:suppress_ssh_strict_kex_ordering_log` - boolean that suppresses OTP
      SSH debug messages for strict KEX ordering. Defaults to `true`.  Note:
      the filter is installed when the server starts and removed when it stops.
      If a test crashes the filter may persist into the next test;

    * `:daemon`           - options to pass directly to `:ssh.daemon/2`;

    * `:suppress_warning` - Suppresses IO warnings on expectation failures
      related to this instance. Defaults to `false`;

  ## Examples

      host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
      auth_key = :public_key.generate_key({:rsa, 2_048, 65_537})
      {:RSAPrivateKey, _, mod, exp, _, _, _, _, _, _, _} = auth_key
      auth_public_key = {:RSAPublicKey, mod, exp}
      user_dir = SSHClient.write_user_dir_pem!(auth_key, "id_rsa")

      TestServer.SSH.start!(
        port: 2222,
        host_keys: [host_key],
        auth_keys: [{"user", auth_public_key}]
      )

      TestServer.SSH.handle(
        to: fn {:data, _channel_id, _want_reply, _data}, state ->
          {:reply, "pong", state}
        end,
        match: fn {:data, _channel_id, _want_reply, data}, _state ->
          data == "ping"
        end
      )

      TestServer.SSH.handle()

      [%{fingerprint: host_fingerprint}] = TestServer.SSH.host_keys()

      assert {:ok, conn} =
        SSHClient.connect(
          TestServer.SSH.address(),
          user: "user",
          auth_methods: "publickey",
          user_dir: user_dir,
          silently_accept_hosts: fn _peer, fingerprint ->
            fingerprint == host_fingerprint
          end
        )

      assert {:ok, channel_id} = SSHClient.session_channel(conn)
      assert SSHClient.send(conn, channel_id, "echo") == :ok
      assert SSHClient.receive_data(conn, channel_id) == {:ok, "echo"}
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert SSHClient.receive_data(conn, channel_id) == {:ok, "pong"}
      assert SSHClient.close(conn) == :ok
  """
  @spec start(keyword()) :: {:ok, TestServer.instance()} | {:error, term()}
  def start(options \\ []) do
    TestServer.start_instance(__MODULE__, options, &verify!/1)
  end

  defp verify!(instance) do
    verify_handlers!(instance)
    verify_channels!(instance)
  end

  defp verify_channels!(instance) do
    instance
    |> Instance.channels()
    |> Enum.filter(&is_nil(&1.channel_id))
    |> case do
      [] ->
        :ok

      unused_channels ->
        raise """
        #{TestServer.format_instance(__MODULE__, instance)} has channels that were not used:

        #{Instance.format_channels(unused_channels)}
        """
    end
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
        #{TestServer.format_instance(__MODULE__, instance)} did not receive a message for these handlers before the test ended:

        #{Instance.format_handlers(active_handlers)}
        """
    end
  end

  @doc """
  Shuts down the current test server SSH instance.

  ## Examples

      _instance = TestServer.SSH.start!()
      {address, port} = TestServer.SSH.address()
      :ok = TestServer.SSH.stop()

      assert SSHClient.connect(TestServer.SSH.address()) == {:error, :econnrefused}
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Shuts down a test server SSH instance.
  """
  @spec stop(TestServer.instance()) :: :ok | {:error, term()}
  def stop(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    :ok = Server.stop(Instance.options(instance))

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

      TestServer.SSH.start!(port: 2222)

      assert TestServer.SSH.address() == {"localhost", 2222}
      assert TestServer.SSH.address(host: "myserver.test") == {"myserver.test", 2222}
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

  @spec channel() :: channel()
  def channel, do: channel([])

  @doc """
  Adds an expected channel to the current test server.

  ## Options

    * `:messages` - list of message types to dispatch to handlers, or `:all`.
      Defaults to `[:exec, :data]`. Available types: `:exec`, `:data`, `:env`,
      `:pty`, `:shell`, `:eof`;

  ## Examples

      channel_1 = TestServer.SSH.channel()
      channel_2 = TestServer.SSH.channel()

      TestServer.SSH.handle(channel_1, to: fn _data, state -> {:reply, "channel 1", state} end)
      TestServer.SSH.handle(channel_2, to: fn _data, state -> {:reply, "channel 2", state} end)

      assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
      assert {:ok, channel_id_1} = SSHClient.session_channel(conn)
      assert {:ok, channel_id_2} = SSHClient.session_channel(conn)
      assert SSHClient.exec(conn, channel_id_2, "ping") == :ok
      assert SSHClient.exec(conn, channel_id_1, "ping") == :ok
      assert SSHClient.receive_data(conn, channel_id_1) == {:ok, "channel 2"}
      assert SSHClient.receive_data(conn, channel_id_2) == {:ok, "channel 1"}
      assert SSHClient.close(conn) == :ok
  """
  @spec channel(keyword()) :: channel()
  def channel(options) when is_list(options) do
    instance = TestServer.autostart_instance(__MODULE__)

    channel(instance, options)
  end

  @doc """
  Adds an expected channel to a test server instance.

  See `channel/1` for options.
  """
  @spec channel(TestServer.instance(), keyword()) :: channel()
  def channel(instance, options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :messages, [:exec, :data])

    {:ok, channel} = Instance.register(instance, {:channel, options, stacktrace})

    {instance, channel.ref}
  end

  def handle, do: handle([])

  @spec handle(channel() | keyword()) :: :ok
  def handle(options) when is_list(options) do
    instance = TestServer.autostart_instance(__MODULE__)

    channel =
      case Instance.channels(instance) do
        [channel] ->
          {instance, channel.ref}

        [] ->
          channel(instance, [])

        _multiple_channels ->
          raise "Multiple channels available, please pass channel to `TestServer.SSH.handle/2`"
      end

    handle(channel, options)
  end

  def handle(channel), do: handle(channel, [])

  @doc """
  Adds a handler to a test server SSH channel.

  Handlers are matched FIFO (first in, first out). Any messages not matched by
  a handler, or any handlers not consumed by a message, will raise an error in
  the test case.

  The `:to` callback can be either a two-arity `t:handler_fun/0` or a
  three-arity `t:raw_handler_fun/0`. A two-arity handler uses the default SSH
  handling, including request acknowledgements, sending replies, and closing
  `:exec` channels. A three-arity handler gives you full control over the SSH
  connection response.

  ## Options

    * `:match` - a `t:match_fun/0` function that returns a boolean. Defaults to
      matching anything;

    * `:to`    - a `t:handler_fun/0` or `t:raw_handler_fun/0` function called
      when the handler matches. Defaults to send back the received data for
      `:exec` and `:data` type channel messages, with no `:data` message
      returned for any other message types;

  ## `:to` return options

  The `{:reply, {data, options}, state}` return from a `t:handler_fun/0` allows
  you to specify options in the options keyword list:

    * `:data_type_code` - an integer SSH data type code to send with the reply,
      defaults to `0` (SSH_MSG_CHANNEL_DATA);

    * `:exit_status`    - an integer exit status to send when finishing an `:exec`
      channel, defaults to `0`. Ignored for other channel types;

  ## Examples

      TestServer.SSH.handle(
        to: fn {:data, _channel_id, _want_reply, _data}, state ->
          {:reply, "pong", state}
        end,
        match: fn {:data, _channel_id, _want_reply, data}, _state ->
          data == "ping"
        end
      )

      TestServer.SSH.handle()

      assert {:ok, conn} = SSHClient.connect(TestServer.SSH.address())
      assert {:ok, channel_id} = SSHClient.session_channel(conn)
      assert SSHClient.send(conn, channel_id, "echo") == :ok
      assert SSHClient.receive_data(conn, channel_id) == {:ok, "echo"}
      assert SSHClient.send(conn, channel_id, "ping") == :ok
      assert SSHClient.receive_data(conn, channel_id) == {:ok, "pong"}
  """
  @spec handle(channel(), keyword()) :: :ok
  def handle({instance, channel_ref} = _channel, options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] =
      TestServer.pruned_stacktrace(__MODULE__)

    options = Keyword.put_new(options, :to, &default_handler/2)

    {:ok, _handler} = Instance.register(instance, {:handle, channel_ref, options, stacktrace})

    :ok
  end

  defp default_handler({:exec, _channel_id, _want_reply, command}, state),
    do: {:reply, to_string(command), state}

  defp default_handler({:data, _channel_id, _type, data}, state),
    do: {:reply, data, state}

  defp default_handler(_message, state),
    do: {:ok, state}

  @doc """
  Fetches the host keys for the current test server.

  ## Examples

      _instance = TestServer.SSH.start!()
      [host_key | _] = TestServer.SSH.host_keys()

      assert {:ok, _conn} =
        SSHClient.connect(
          TestServer.SSH.address(),
          silently_accept_hosts: fn _peer, fingerprint ->
            fingerprint == host_key.fingerprint
          end)
  """
  @spec host_keys() :: [host_key()]
  def host_keys, do: host_keys(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Fetches the generated host keys for a test server instance.

  See `host_keys/0` for more.
  """
  @spec host_keys(TestServer.instance()) :: [host_key()]
  def host_keys(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    options = Instance.options(instance)

    case is_list(options[:host_keys]) do
      true ->
        options[:host_keys]

      false ->
        raise "#{TestServer.format_instance(__MODULE__, instance)} is running with `[host_keys: function]` option"
    end
  end
end
