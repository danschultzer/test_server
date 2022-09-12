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
    case InstanceManager.start_instance(options) do
      {:ok, instance} ->
        ExUnit.Callbacks.on_exit(fn -> stop(instance) end)

        {:ok, instance}

      {:error, error} ->
        raise_start_failure({:error, error})
    end
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

  @doc """
  Shuts down the current test server instance
  """
  @spec stop() :: :ok | {:error, term()}
  def stop do
    case InstanceManager.get_by_caller(self()) do
      nil -> :ok
      instance -> stop(instance)
    end
  end

  @doc """
  Shuts down a test server instance
  """
  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(instance) do
    case Process.alive?(instance) do
      true ->
        verify_routes!(instance)
        InstanceManager.stop_instance(instance)

      false ->
        :ok
    end
  end

  defp verify_routes!(instance) do
    case Instance.active_routes(instance) do
      [] ->
        :ok

      routes ->
        raise """
          The test ended before the following #{inspect(__MODULE__)} route(s) received a request:

          #{Instance.routes_info(routes)}
        """
    end
  end

  @spec url() :: binary()
  def url, do: url("")

  @spec url(binary() | keyword()) :: binary()
  def url(uri) when is_binary(uri), do: url(uri, [])
  def url(opts) when is_list(opts), do: url("", opts)

  @doc """
  Produces a URL for the test server instance.

  ## Options
    * `:host` - binary host value, it'll be added to inet for IP 127.0.0.1, defaults to `"localhost"`;
  """
  @spec url(binary(), keyword()) :: binary()
  def url(uri, opts) do
    unless is_nil(opts[:host]) or is_binary(opts[:host]),
      do: raise("Invalid host, got: #{inspect(opts[:host])}")

    instance = fetch_instance!()

    domain = maybe_enable_host(opts[:host])
    options = Instance.get_options(instance)

    "#{Keyword.fetch!(options, :scheme)}://#{domain}:#{Keyword.fetch!(options, :port)}#{uri}"
  end

  defp fetch_instance! do
    case fetch_instance() do
      :error -> raise "#{inspect(Instance)} is not running, did you start it?"
      {:ok, instance} -> instance
    end
  end

  defp fetch_instance do
    case InstanceManager.get_by_caller(self()) do
      nil -> :error
      instance -> {:ok, instance}
    end
  end

  defp maybe_enable_host(nil), do: "localhost"

  defp maybe_enable_host(host) do
    :inet_db.set_lookup([:file, :dns])
    :inet_db.add_host({127, 0, 0, 1}, [String.to_charlist(host)])

    host
  end

  @doc """
  Adds a route to the test server.

  ## Options

    * `:via`     - matches the route against some specific HTTP method(s) specified as an atom, like `:get` or `:put`, or a list, like `[:get, :post]`.
    * `:match`   - an anonymous function that will be called to see if a route matches, defaults to matching with arguments of uri and `:via` option.
    * `:to`      - a Plug or anonymous function that will be called when the route matches.
  """
  @spec add(binary(), keyword()) :: :ok | {:error, term()}
  def add(uri, options \\ []) when is_binary(uri) and is_list(options) do
    {:ok, instance} = autostart()

    {:current_stacktrace, [_process, _test_server | stacktrace]} =
      Process.info(self(), :current_stacktrace)

    options = Keyword.put_new(options, :to, &default_response_handler/1)

    Instance.register(instance, {uri, options, stacktrace})
  end

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
  Fetches the generated x509 suite for the current test server instance.
  """
  @spec x509_suite() :: term()
  def x509_suite, do: x509_suite(fetch_instance!())

  @doc """
  Fetches the generated x509 suite for a test server instance.
  """
  @spec x509_suite(pid()) :: term()
  def x509_suite(instance) do
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
