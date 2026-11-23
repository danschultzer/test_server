defmodule TestServer do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)
             |> then(&Regex.replace(~r/\[(`[^`]+`)\]\([^)]+\)/, &1, "\\1"))
             |> String.trim()

  @type instance :: {module(), pid()}
  @type stacktrace :: list()
  @type cacerts :: [binary()]
  @type ip_address :: :inet.ip_address() | :any | :loopback
  @type ipfamily :: :inet | :inet6
  @type port_number :: :inet.port_number()

  alias TestServer.InstanceManager

  @doc false
  def pruned_stacktrace(calling_module) do
    {:current_stacktrace, [{Process, :info, _, _} | stacktrace]} =
      Process.info(self(), :current_stacktrace)

    first_module_entry =
      stacktrace
      |> Enum.reverse()
      |> Enum.find(fn {mod, _, _, _} -> mod == calling_module end)

    [first_module_entry] ++ prune_stacktrace(stacktrace, calling_module)
  end

  defp prune_stacktrace([{TestServer, _, _, _} | t], mod), do: prune_stacktrace(t, mod)

  defp prune_stacktrace([{TestServer.InstanceManager, _, _, _} | t], mod),
    do: prune_stacktrace(t, mod)

  defp prune_stacktrace([{mod, _, _, _} | t], mod), do: prune_stacktrace(t, mod)
  defp prune_stacktrace([{ExUnit.Assertions, _, _, _} | t], mod), do: prune_stacktrace(t, mod)
  defp prune_stacktrace([{ExUnit.Runner, _, _, _} | _], _mod), do: []
  defp prune_stacktrace([h | t], mod), do: [h | prune_stacktrace(t, mod)]
  defp prune_stacktrace([], _mod), do: []

  @doc false
  def start_instance(protocol_module, options, verify_instance_fn) do
    case ExUnit.fetch_test_supervisor() do
      {:ok, _sup} ->
        start_with_ex_unit(protocol_module, options, verify_instance_fn)

      :error ->
        raise ArgumentError,
              "cannot start a #{inspect(protocol_module)} instance outside a test process"
    end
  end

  defp start_with_ex_unit(protocol_module, options, verify_instance_fn) do
    caller = self()

    case InstanceManager.start_instance(caller, protocol_module, options) do
      {:ok, instance} ->
        put_ex_unit_on_exit_callback(instance, verify_instance_fn)

        {:ok, instance}

      {:error, {exception, stacktrace}} when is_exception(exception) ->
        reraise exception, stacktrace

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_ex_unit_on_exit_callback(instance, verify_instance_fn) do
    {protocol_module, _instance_pid} = instance

    ExUnit.Callbacks.on_exit({TestServer, instance}, fn ->
      errors = run_verify_instance(instance, protocol_module, verify_instance_fn)
      :ok = InstanceManager.delete_instance_entry(instance)
      :ok = raise_on_exit!(errors)
      :ok = raise_errors!(errors)
    end)
  end

  defp run_verify_instance(instance, protocol_module, verify_instance_fn) do
    verify_errors =
      case InstanceManager.fetch_instance_entry(instance) do
        {:ok, %{status: :running}} ->
          capture_exceptions(instance, [verify_instance_fn, &protocol_module.stop(&1)])

        {:ok, %{status: {:stopped, _stacktrace}}} ->
          capture_exceptions(instance, [])

        {:ok, %{status: {:exited, reason}}} ->
          capture_exceptions([instance, reason], &raise_instance_exited!/2)

        {:error, :not_found} ->
          capture_exceptions(instance, &raise_instance_not_found!/1)
      end

    recorded_errors =
      case InstanceManager.fetch_instance_entry(instance) do
        {:ok, %{errors: errors}} -> errors
        {:error, :not_found} -> []
      end

    recorded_errors ++ verify_errors
  end

  defp capture_exceptions(args, funs) do
    funs
    |> List.wrap()
    |> Enum.reduce([], fn fun, acc ->
      case capture_exception(args, fun) do
        :ok -> acc
        {:error, error} -> acc ++ [error]
      end
    end)
  end

  defp capture_exception(args, fun) do
    apply(fun, List.wrap(args))

    :ok
  rescue
    exception -> {:error, {exception, __STACKTRACE__}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp raise_instance_exited!(instance, reason) do
    raise RuntimeError, """
    expected #{format_instance(instance)} to be running, but it exited with reason:

    #{Exception.format_exit(reason)}
    """
  end

  defp raise_instance_not_found!(instance) do
    raise RuntimeError,
          "expected #{format_instance(instance)} to be a TestServer-managed instance"
  end

  defp raise_on_exit!(errors) do
    Enum.each(errors, fn
      {:exit, reason} -> exit(reason)
      {_exception, _stacktrace} -> :ok
    end)
  end

  defp raise_errors!([]), do: :ok

  defp raise_errors!([{exception, stacktrace}]) do
    reraise(exception, stacktrace)
  end

  defp raise_errors!(errors) do
    message =
      Enum.map_join(errors, "\n\n", fn {exception, stacktrace} ->
        Exception.format(:error, exception, stacktrace)
      end)

    raise RuntimeError, "expected no errors, got:\n\n#{message}"
  end

  @doc false
  def assert_instance_alive!(instance) do
    case InstanceManager.fetch_instance_entry(instance) do
      {:ok, %{status: :running}} -> instance
      {:ok, %{status: {:stopped, stacktrace}}} -> raise_instance_stopped!(instance, stacktrace)
      {:ok, %{status: {:exited, reason}}} -> raise_instance_exited!(instance, reason)
      {:error, :not_found} -> raise_instance_not_found!(instance)
    end

    :ok
  end

  defp raise_instance_stopped!(instance, stacktrace) do
    raise RuntimeError, """
    expected #{format_instance(instance)} to be running, but it was stopped at:

    #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
    """
  end

  @doc false
  def stop_instance(instance) do
    case InstanceManager.stop_instance(instance) do
      {:ok, {:stopped, _stacktrace}} -> :ok
      {:error, :not_found} -> raise_instance_not_found!(instance)
      {:error, {:stopped, stacktrace}} -> raise_instance_stopped!(instance, stacktrace)
      {:error, {:exited, reason}} -> raise_instance_exited!(instance, reason)
    end
  end

  @doc false
  def format_instance({protocol_module, instance_pid}) do
    instance_module = Module.concat(protocol_module, Instance)

    "#{inspect(instance_module)} #{inspect(instance_pid)}"
  end

  @doc false
  def raise_start_failure!(protocol_module, options, reason) do
    raise "could not start #{inspect(protocol_module)} instance#{format_address(options)}:\n\n#{Exception.format_exit(reason)}"
  end

  defp format_address(options) do
    case {Keyword.get(options, :ip, :any), Keyword.get(options, :port)} do
      {:any, nil} -> ""
      {:any, port} -> " on port #{port}"
      {ip, nil} -> " on #{format_ip(ip)}"
      {ip, port} -> " on #{format_ip(ip)}:#{port}"
    end
  end

  defp format_ip({_, _, _, _} = ip), do: :inet.ntoa(ip)
  defp format_ip({_, _, _, _, _, _, _, _} = ip), do: "[#{:inet.ntoa(ip)}]"
  defp format_ip(:loopback), do: "localhost"

  @doc false
  def supervise_server(server_pid, shutdown_fn) do
    spawn_link(fn ->
      false = Process.flag(:trap_exit, true)
      monitor = Process.monitor(server_pid)

      receive do
        {:DOWN, ^monitor, :process, ^server_pid, reason} -> exit({:shutdown, reason})
        {:EXIT, _pid, _reason} -> shutdown_fn.(server_pid)
      end
    end)

    :ok
  end

  @doc false
  def autostart_instance(protocol_module) do
    case InstanceManager.fetch_instance_by_caller_protocol(self(), protocol_module) do
      :error -> protocol_module.start!()
      {:ok, instance} -> instance
    end
  end

  @doc false
  def validate_port!(options) do
    port = Keyword.get(options, :port, 0)

    unless is_integer(port) and port >= 0 and port <= 65_535,
      do:
        raise(
          ArgumentError,
          "expected :port to be an integer from 0 to 65535, got: #{inspect(port)}"
        )

    port
  end

  @doc false
  def validate_ip!(options) do
    ipfamily = validate_ipfamily!(options)
    ip = validate_ip!(options, Keyword.get(options, :ipfamily))

    {ipfamily, ip}
  end

  defp validate_ip!(options, ipfamily) when is_list(options) do
    ip = Keyword.get(options, :ip, :loopback)

    case {ip, ipfamily} do
      {{_, _, _, _}, ipfamily} when ipfamily in [:inet, nil] ->
        ip

      {{_, _, _, _, _, _, _, _}, ipfamily} when ipfamily in [:inet6, nil] ->
        ip

      {ip, _} when ip in [:loopback, :any] ->
        ip

      {_ip, :inet} ->
        raise ArgumentError, "expected :ip to be an IPv4 tuple, got: #{inspect(ip)}"

      {_ip, :inet6} ->
        raise ArgumentError, "expected :ip to be an IPv6 tuple, got: #{inspect(ip)}"

      {_ip, nil} ->
        raise ArgumentError,
              "expected :ip to be an IP tuple, :any, or :loopback, got: #{inspect(ip)}"
    end
  end

  defp validate_ipfamily!(options) do
    ip = Keyword.get(options, :ip)
    ipfamily = Keyword.get(options, :ipfamily, ipfamily(ip))

    case ipfamily do
      :inet ->
        :inet

      :inet6 ->
        :inet6

      other ->
        raise(
          ArgumentError,
          "expected :ipfamily to be one of :inet or :inet6, got: #{inspect(other)}"
        )
    end
  end

  defp ipfamily({_, _, _, _, _, _, _, _}), do: :inet6
  defp ipfamily(_other), do: :inet

  @doc false
  def validate_function_option!(options, option, arity) do
    value = Keyword.get(options, option)
    arities = List.wrap(arity)

    case Enum.any?(arities, &is_function(value, &1)) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "expected #{inspect(option)} to be a #{Enum.join(arities, " or ")}-arity function, got: #{inspect(value)}"
    end
  end

  @doc false
  def validate_timeout!(options, default_timeout) do
    timeout = Keyword.get(options, :timeout, default_timeout)

    case is_integer(timeout) and timeout > 0 do
      true ->
        timeout

      false ->
        raise ArgumentError,
              "expected :timeout to be a positive integer, got: #{inspect(timeout)}"
    end
  end

  @levels [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug, :none, :all]

  @doc false
  def validate_log_level!(level) when level in @levels, do: :ok

  def validate_log_level!(level) do
    raise ArgumentError,
          "expected :log_level in :daemon to be one of #{Enum.map_join(@levels, ", ", &inspect/1)}, got: #{inspect(level)}"
  end

  @doc false
  def split_atom_options_with_ipfamily(options, ipfamily_options) do
    {atoms, options} = Enum.split_with(options, &is_atom/1)

    atoms =
      case atoms -- ~w(inet inet6)a do
        ^atoms ->
          atoms ++ List.wrap(Keyword.get(ipfamily_options, :ipfamily))

        _atoms ->
          atoms
      end

    {atoms, options}
  end

  @doc false
  def fetch_protocol_instance!(protocol_module) do
    instance_module = Module.concat(protocol_module, Instance)

    case InstanceManager.fetch_instance_by_caller_protocol(self(), protocol_module) do
      :error -> raise "expected #{inspect(instance_module)} to be running"
      {:ok, instance} -> instance
    end
  end

  @doc false
  def add_host(options) do
    Keyword.validate!(options, [:host, :port, :ip, :ipfamily])

    case Keyword.has_key?(options, :host) do
      false ->
        "localhost"

      true ->
        host = Keyword.fetch!(options, :host)

        do_add_host(host, options)
    end
  end

  defp do_add_host(host, options) when is_binary(host) do
    ipfamily = Keyword.get(options, :ipfamily, :inet)
    host_ip = resolve_ip(Keyword.get(options, :ip), ipfamily)
    name = String.to_charlist(host)

    lookup =
      case Keyword.fetch!(:inet_db.get_rc(), :lookup) do
        [:file | methods] -> methods
        methods -> methods
      end

    :ok = :inet_db.set_lookup([:file])
    aliases = list_aliases_for_ip(host_ip)
    ips = list_ips_for_hostname(name, ipfamily)
    :ok = :inet_db.set_lookup([:file | lookup])

    ips != [] &&
      raise ArgumentError, "expected :host not to resolve to an IP address, got: #{inspect(ips)}"

    :inet_db.add_host(host_ip, [name | aliases])

    ExUnit.Callbacks.on_exit(fn ->
      case aliases do
        [] -> :inet_db.del_host(host_ip)
        aliases -> :inet_db.add_host(host_ip, aliases)
      end
    end)

    host
  end

  defp do_add_host(host, _options) do
    raise(ArgumentError, "expected :host to be a binary, got: #{inspect(host)}")
  end

  defp resolve_ip({0, 0, 0, 0}, _inet), do: {127, 0, 0, 1}
  defp resolve_ip({0, 0, 0, 0, 0, 0, 0, 0}, _inet), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp resolve_ip({_, _, _, _} = ip, _inet), do: ip
  defp resolve_ip({_, _, _, _, _, _, _, _} = ip, _inet), do: ip
  defp resolve_ip(_, :inet6), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp resolve_ip(_, :inet), do: {127, 0, 0, 1}

  defp list_aliases_for_ip(ip) do
    case :inet.gethostbyaddr(ip) do
      {:ok, {:hostent, name, aliases, _inet, _, _ips}} -> [name | aliases]
      {:error, :nxdomain} -> []
    end
  end

  defp list_ips_for_hostname(name, ipfamily) do
    case :inet.gethostbyname(name, ipfamily) do
      {:ok, {:hostent, _name, _aliases, _inet, _, ips}} -> ips
      {:error, _} -> []
    end
  end

  @doc false
  def report_error(instance, {exception, stacktrace}, options) do
    unless Keyword.get(options, :suppress_warning, false),
      do: IO.warn(Exception.format(:error, exception, stacktrace))

    InstanceManager.add_error(instance, {exception, stacktrace})

    :ok
  end

  @doc false
  @spec put_tls_options(keyword(), keyword()) :: keyword()
  def put_tls_options(options, x509_opts \\ []) do
    tls_options = Keyword.get(options, :tls, [])

    case Keyword.take(tls_options, [:key, :keyfile]) do
      [] ->
        suite = X509.Test.Suite.new(x509_opts)
        type = elem(suite.server_key, 0)
        server_key = X509.PrivateKey.to_der(suite.server_key)
        cert = X509.Certificate.to_der(suite.valid)

        tls =
          [
            key: {type, server_key},
            cert: cert,
            cacerts: suite.chain ++ suite.cacerts
          ]

        options
        |> Keyword.put(:tls, Keyword.merge(tls, tls_options))
        |> Keyword.put(:cacerts, suite.cacerts)

      _any ->
        options
    end
  end
end
