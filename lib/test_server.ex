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
    raise "could not start #{inspect(protocol_module)} instance#{format_port(options)}:\n\n#{Exception.format_exit(reason)}"
  end

  defp format_port(options) do
    case Keyword.get(options, :port) do
      port when is_integer(port) -> " on port #{port}"
      _no_port -> ""
    end
  end

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
  def open_port(options) do
    {port, listen_options} =
      case Keyword.get(options, :port, 0) do
        {port, options} -> {port, options}
        port -> {port, []}
      end

    port = validate_port!(port: port)

    with {:ok, socket} <- :gen_tcp.listen(port, listen_options),
         {:ok, port} <- :inet.port(socket),
         true <- :erlang.port_close(socket) do
      {:ok, port}
    else
      {:error, reason} ->
        {:error,
         RuntimeError.exception("could not listen on port #{inspect(port)}: #{inspect(reason)}")}
    end
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
  def host(options) do
    host = Keyword.get(options, :host)

    unless is_nil(host) or is_binary(host),
      do: raise(ArgumentError, "expected :host to be a binary or nil, got: #{inspect(host)}")

    case host do
      nil ->
        "localhost"

      host ->
        :inet_db.set_lookup([:file, :dns])
        :inet_db.add_host({127, 0, 0, 1}, [String.to_charlist(host)])
        :inet_db.add_host({0, 0, 0, 0, 0, 0, 0, 1}, [String.to_charlist(host)])

        host
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
