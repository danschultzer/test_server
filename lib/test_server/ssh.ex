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
          | {:ok, term()}

  @doc """
  Start a test server SSH instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`        - integer port number, defaults to random available port;
    * `:credentials` - list of `{user, password}` or `{user, {:public_key, pem}}`
      tuples. Defaults to `[]` (no authentication required);
    * `:host_key`    - RSA private key for the server. Defaults to a randomly
      generated 2048-bit RSA key;

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

  @doc """
  Returns the address of the current test server SSH instance.

  ## Examples

      TestServer.SSH.start()
      {"localhost", port} = TestServer.SSH.address()
  """
  @spec address() :: {binary(), non_neg_integer()}
  def address, do: address(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Returns the address of a test server SSH instance.
  """
  @spec address(pid()) :: {binary(), non_neg_integer()}
  def address(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    options = Instance.get_options(instance)

    {"localhost", Keyword.fetch!(options, :port)}
  end

  @doc """
  Adds a channel to the current test server.

  ## Examples

      {:ok, channel} = TestServer.SSH.channel()

      TestServer.SSH.add(channel, to: fn {:exec, command}, state ->
        {:reply, "got: \#{command}", state}
      end)

      {"localhost", port} = TestServer.SSH.address()
  """
  @spec channel() :: {:ok, channel()}
  def channel, do: channel(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Adds a channel to a test server instance.
  """
  @spec channel(pid()) :: {:ok, channel()}
  def channel(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    {:ok, channel_ref} = Instance.register(instance, {:channel})

    {:ok, {instance, channel_ref}}
  end

  @doc """
  Adds a handler to a test server SSH channel.

  Handlers are matched FIFO (first in, first out). Any messages not matched by
  a handler, or any handlers not consumed by a message, will raise an error in
  the test case.

  ## Options

    * `:match` - a function/2 `fn {type, input}, state -> boolean end` that receives
      the tagged input and state and returns a boolean. Defaults to matching any input;
    * `:to`    - a function/2 `fn {type, input}, state -> response end` called when
      the handler matches. `type` is `:exec` or `:data`. Defaults to echoing the
      input back;

  ## Examples

      {:ok, channel} = TestServer.SSH.channel()

      TestServer.SSH.add(to: fn {:exec, command}, state ->
        {:reply, "got: \#{command}", state}
      end)

      TestServer.SSH.add(match: fn {_type, input}, _state -> input == "deploy" end)

      TestServer.SSH.add(channel, to: fn {:exec, command}, state ->
        {:reply, "got: \#{command}", state}
      end)
  """
  @spec add(channel() | keyword()) :: :ok
  def add(channel_or_options \\ [])

  def add(options) when is_list(options) do
    {:ok, channel} = channel()
    add(channel, options)
  end

  def add({instance, _channel_ref} = channel) when is_pid(instance) do
    add(channel, [])
  end

  @spec add(channel(), keyword()) :: :ok
  def add({instance, channel_ref}, options) when is_pid(instance) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_register_entry, _first_module_entry | stacktrace] =
      TestServer.get_pruned_stacktrace(__MODULE__)

    {:ok, _handler} = Instance.register(instance, {:handler, {channel_ref, options, stacktrace}})

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
