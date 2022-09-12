defmodule TestServer do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias Plug.Conn
  alias TestServer.{Instance, InstanceManager}

  @doc """
  Start a test server instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`             - integer of port number, defaults to random port that can be opened;
    * `:scheme`           - an atom for the http scheme. Defaults to `:http`;
    * `:cowboy_options`   - See [Cowboy docs](https://ninenines.eu/docs/en/cowboy/2.5/manual/cowboy_http/)
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(options \\ []) do
    case ExUnit.fetch_test_supervisor() do
      {:ok, sup} ->
        start_with_ex_unit(options, sup)

      :error ->
        raise ArgumentError, "can only be called in a test process"
    end
  end

  defp start_with_ex_unit(options, _sup) do
    [_first_module_entry | stacktrace] = get_stacktrace()

    case InstanceManager.start_instance(self(), stacktrace, options) do
      {:ok, instance} ->
        put_ex_unit_on_exit_callback(instance)

        {:ok, instance}

      {:error, error} ->
        raise_start_failure({:error, error})
    end
  end

  defp put_ex_unit_on_exit_callback(instance) do
    ExUnit.Callbacks.on_exit(fn ->
      case Process.alive?(instance) do
        true ->
          verify_routes!(instance)
          stop(instance)

        false ->
          :ok
      end
    end)
  end

  defp raise_start_failure({:error, {{:EXIT, reason}, _spec}}) do
    raise_start_failure({:error, reason})
  end

  defp raise_start_failure({:error, error}) do
    raise """
    EXIT when starting #{__MODULE__.Instance}:

    #{Exception.format_exit(error)}
    """
  end

  defp verify_routes!(instance) do
    case Instance.active_routes(instance) do
      [] ->
        :ok

      routes ->
        raise """
        The test ended before the following #{inspect(Instance)} route(s) received a request:

        #{Instance.format_routes(routes)}
        """
    end
  end

  @doc """
  Shuts down the current test server.
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(fetch_instance!())

  @doc """
  Shuts down a test server instance.
  """
  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(instance) do
    instance_alive!(instance)

    InstanceManager.stop_instance(instance)
  end

  defp instance_alive!(instance) do
    case Process.alive?(instance) do
      true -> :ok
      false -> raise "The #{inspect(Instance)} #{inspect(instance)} is not running"
    end
  end

  @spec url() :: binary()
  def url, do: url("")

  @spec url(binary() | keyword()) :: binary()
  def url(uri) when is_binary(uri), do: url(uri, [])
  def url(opts) when is_list(opts), do: url("", opts)
  def url(instance) when is_pid(instance), do: url(instance, "", [])

  @doc """
  Produces a URL for current test server.

  ## Options
    * `:host` - binary host value, it'll be added to inet for IP 127.0.0.1, defaults to `"localhost"`;
  """
  @spec url(binary(), keyword()) :: binary()
  def url(uri, opts) when is_binary(uri), do: url(fetch_instance!(), uri, opts)

  @spec url(pid(), binary()) :: binary()
  def url(instance, uri) when is_pid(instance), do: url(instance, uri, [])

  @doc """
  Produces a URL for a test server instance.

  See `url/2` for options.
  """
  @spec url(pid(), binary(), keyword()) :: binary()
  def url(instance, uri, opts) do
    instance_alive!(instance)

    unless is_nil(opts[:host]) or is_binary(opts[:host]),
      do: raise("Invalid host, got: #{inspect(opts[:host])}")

    domain = maybe_enable_host(opts[:host])
    options = Instance.get_options(instance)

    "#{Keyword.fetch!(options, :scheme)}://#{domain}:#{Keyword.fetch!(options, :port)}#{uri}"
  end

  defp fetch_instance! do
    case fetch_instance() do
      :error -> raise "No current #{inspect(Instance)} is not running"
      {:ok, instance} -> instance
    end
  end

  defp fetch_instance do
    case InstanceManager.get_by_caller(self()) do
      nil ->
        :error

      [instance] ->
        {:ok, instance}

      [_instance | _rest] = instances ->
        [{m, f, a, _} | _stacktrace] = get_stacktrace()

        formatted_instances =
          instances
          |> Enum.map(&{&1, Instance.get_options(&1)})
          |> Enum.with_index()
          |> Enum.map_join("\n\n", fn {{instance, options}, index} ->
            """
            ##{index + 1}: #{inspect(instance)}
                #{Enum.map_join(options[:stacktrace], "\n    ", &Exception.format_stacktrace_entry/1)}")}
            """
          end)

        raise """
        Multiple #{inspect(Instance)}'s running, please pass instance to `#{inspect(m)}.#{f}/#{a}`.

        #{formatted_instances}
        """
    end
  end

  defp maybe_enable_host(nil), do: "localhost"

  defp maybe_enable_host(host) do
    :inet_db.set_lookup([:file, :dns])
    :inet_db.add_host({127, 0, 0, 1}, [String.to_charlist(host)])

    host
  end

  @spec add(binary()) :: :ok | {:error, term()}
  def add(uri), do: add(uri, [])

  @doc """
  Adds a route to the current test server.

  ## Options

    * `:via`     - matches the route against some specific HTTP method(s) specified as an atom, like `:get` or `:put`, or a list, like `[:get, :post]`.
    * `:match`   - an anonymous function that will be called to see if a route matches, defaults to matching with arguments of uri and `:via` option.
    * `:to`      - a Plug or anonymous function that will be called when the route matches.
  """
  @spec add(binary(), keyword()) :: :ok | {:error, term()}
  def add(uri, options) when is_binary(uri) do
    {:ok, instance} = autostart()

    add(instance, uri, options)
  end

  @spec add(pid(), binary()) :: :ok | {:error, term()}
  def add(instance, uri) when is_pid(instance) and is_binary(uri), do: add(instance, uri, [])

  @doc """
  Adds a route to a test server instance.

  See `add/2` for options.
  """
  @spec add(pid(), binary(), keyword()) :: :ok | {:error, term()}
  def add(instance, uri, options) when is_pid(instance) and is_binary(uri) and is_list(options) do
    instance_alive!(instance)

    [_first_module_entry | stacktrace] = get_stacktrace()

    options = Keyword.put_new(options, :to, &default_response_handler/1)

    Instance.register(instance, {:plug_router_to, {uri, options, stacktrace}})
  end

  defp get_stacktrace do
    {:current_stacktrace, [{Process, :info, _, _} | stacktrace]} =
      Process.info(self(), :current_stacktrace)

    first_module_entry =
      stacktrace
      |> Enum.reverse()
      |> Enum.find(fn {mod, _, _, _} -> mod == __MODULE__ end)

    [first_module_entry] ++ prune_stacktrace(stacktrace)
  end

  # Remove TestServer
  defp prune_stacktrace([{__MODULE__, _, _, _} | t]), do: prune_stacktrace(t)

  # Assertions can pop-up in the middle of the stack
  defp prune_stacktrace([{ExUnit.Assertions, _, _, _} | t]), do: prune_stacktrace(t)

  # As soon as we see a Runner, it is time to ignore the stacktrace
  defp prune_stacktrace([{ExUnit.Runner, _, _, _} | _]), do: []

  # All other cases
  defp prune_stacktrace([h | t]), do: [h | prune_stacktrace(t)]
  defp prune_stacktrace([]), do: []

  defp autostart do
    case fetch_instance() do
      :error -> start()
      {:ok, instance} -> {:ok, instance}
    end
  end

  defp default_response_handler(conn) do
    Conn.send_resp(conn, 200, to_string(Conn.get_http_protocol(conn)))
  end

  @doc """
  Adds a plug to the current test server.

  This plug will be called for all requests before route is matched.
  """
  @spec plug(atom() | function()) :: :ok | {:error, term()}
  def plug(plug) when is_atom(plug) or is_function(plug) do
    {:ok, instance} = autostart()

    plug(instance, plug)
  end

  @doc """
  Adds a route to a test server instance.

  See `plug/1` for options.
  """
  @spec plug(pid(), atom() | function()) :: :ok | {:error, term()}
  def plug(instance, plug) do
    [_first_module_entry | stacktrace] = get_stacktrace()

    Instance.register(instance, {:plug, {plug, stacktrace}})
  end

  @doc """
  Fetches the generated x509 suite for the current test server.
  """
  @spec x509_suite() :: term()
  def x509_suite, do: x509_suite(fetch_instance!())

  @doc """
  Fetches the generated x509 suite for a test server instance.
  """
  @spec x509_suite(pid()) :: term()
  def x509_suite(instance) do
    instance_alive!(instance)

    options = Instance.get_options(instance)

    cond do
      not (options[:scheme] == :https) ->
        raise "The #{inspect(Instance)} is not running with `[scheme: :https]` option"

      not Keyword.has_key?(options, :x509_suite) ->
        raise "The #{inspect(Instance)} is running with custom SSL"

      true ->
        options[:x509_suite]
    end
  end
end
