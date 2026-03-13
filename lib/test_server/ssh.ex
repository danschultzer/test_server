defmodule TestServer.SSH do
  @external_resource "lib/test_server/ssh/README.md"
  @moduledoc "lib/test_server/ssh/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias TestServer.SSH.{Instance, Server}

  @type channel :: {pid(), reference()}

  @type handle_response ::
          {:reply, iodata(), term()}
          | {:reply, {iodata(), keyword()}, term()}
          | {:ignore, term()}
          | {:ok, term()}

  @doc """
  Start a test server SSH instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`        - integer port number, defaults to random available port;
    * `:ipfamily`    - `:inet` (default) or `:inet6`;
    * `:credentials` - list of `{user, password}` or `{user, {:public_key, pem}}`
      tuples. Defaults to `[]` (no authentication required);
    * `:host_key`    - RSA private key for the server. Defaults to a randomly
      generated 2048-bit RSA key;
    * `:listen`      - list of message types to dispatch to handlers, or `:all`.
      Defaults to `[:exec, :data]`. Messages not in the list get auto-replied.
      Available types: `:exec`, `:data`, `:env`, `:pty`, `:shell`, `:eof`;

  ## Examples

      {:ok, instance} = TestServer.SSH.start(port: 2222)

      {:ok, instance} = TestServer.SSH.start(credentials: [{"user", "pass"}])
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(options \\ []) do
    TestServer.start_instance(__MODULE__, options, &verify!/1)
  end

  @doc """
  Shuts down the current test server SSH instance.
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Shuts down a test server SSH instance.
  """
  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    Server.stop(Instance.get_options(instance))

    TestServer.stop_instance(__MODULE__, instance)
  end

  @spec address() :: {binary(), non_neg_integer()}
  def address, do: address([])

  @spec address(keyword() | pid()) :: {binary(), non_neg_integer()}
  def address(opts) when is_list(opts), do: address(TestServer.fetch_instance!(__MODULE__), opts)
  def address(instance) when is_pid(instance), do: address(instance, [])

  @doc """
  Returns the address of a test server SSH instance as `{host, port}`.

  ## Options

    * `:host` - binary host value, it'll be added to inet for IP `127.0.0.1`
      and `::1`, defaults to `"localhost"`;

  ## Examples

      TestServer.SSH.start()
      {host, port} = TestServer.SSH.address()
      assert host == "localhost"

      {host, port} = TestServer.SSH.address(host: "myserver.test")
      assert host == "myserver.test"
  """
  @spec address(pid(), keyword()) :: {binary(), non_neg_integer()}
  def address(instance, opts) when is_pid(instance) and is_list(opts) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    host = TestServer.get_host(opts)
    port = instance |> Instance.get_options() |> Keyword.fetch!(:port)

    {host, port}
  end

  @doc """
  Adds a channel to the current test server.

  ## Examples

      {:ok, channel} = TestServer.SSH.channel()

      TestServer.SSH.handle(channel, to: fn {:exec, _ch, _wr, command}, state ->
        {:reply, "got: \#{to_string(command)}", state}
      end)

      port = TestServer.SSH.address()
  """
  @spec channel() :: {:ok, channel()}
  def channel, do: channel(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Adds a channel to a test server instance.
  """
  @spec channel(pid()) :: {:ok, channel()}
  def channel(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)

    {:ok, channel_ref} = Instance.register(instance, {:channel, stacktrace})

    {:ok, {instance, channel_ref}}
  end

  @doc """
  Adds a handler to a test server SSH channel.

  Handlers are matched FIFO (first in, first out). Any messages not matched by
  a handler, or any handlers not consumed by a message, will raise an error in
  the test case.

  Handlers receive raw SSH message tuples:

    * `{:exec, channel_id, want_reply, command}` — command is a charlist
    * `{:data, channel_id, type, data}` — data is binary
    * `{:env, channel_id, want_reply, var, val}`
    * `{:pty, channel_id, want_reply, pty_info}`
    * `{:shell, channel_id, want_reply}`
    * `{:eof, channel_id}`

  ## Options

    * `:match` - a function/2 `fn message, state -> boolean end` that receives
      the raw message and state and returns a boolean. Defaults to matching any input;
    * `:to`    - a function/2 `fn message, state -> response end` called when
      the handler matches. Defaults to echoing the input back;

  ## Examples

      {:ok, channel} = TestServer.SSH.channel()

      TestServer.SSH.handle(to: fn {:exec, _ch, _wr, command}, state ->
        {:reply, to_string(command), state}
      end)

      TestServer.SSH.handle(match: fn {:exec, _ch, _wr, cmd}, _state ->
        to_string(cmd) == "deploy"
      end)

      TestServer.SSH.handle(channel, to: fn {:exec, _ch, _wr, command}, state ->
        {:reply, "got: \#{to_string(command)}", state}
      end)
  """
  @spec handle(channel() | keyword()) :: :ok
  def handle(channel_or_options \\ [])

  def handle(options) when is_list(options) do
    {:ok, channel} = channel()
    handle(channel, options)
  end

  def handle({instance, _channel_ref} = channel) when is_pid(instance) do
    handle(channel, [])
  end

  @spec handle(channel(), keyword()) :: :ok
  def handle({instance, channel_ref}, options) when is_pid(instance) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_register_entry, _first_module_entry | stacktrace] =
      TestServer.get_pruned_stacktrace(__MODULE__)

    {:ok, _handler} = Instance.register(instance, {:handle, {channel_ref, options, stacktrace}})

    :ok
  end

  defp verify!(instance) do
    instance
    |> Instance.handlers()
    |> Enum.reject(& &1.suspended)
    |> case do
      [] ->
        :ok

      active_handlers ->
        raise """
        #{TestServer.format_instance(__MODULE__, instance)} did not receive expected messages:

        #{Instance.format_handlers(active_handlers)}
        """
    end
  end
end
