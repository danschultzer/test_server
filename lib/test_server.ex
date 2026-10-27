defmodule TestServer do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)
             |> then(&Regex.replace(~r/\[(`[^`]+`)\]\([^)]+\)/, &1, "\\1"))

  @type instance :: pid()
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
  def start_instance(protocol_module, options, verify_fn) do
    case ExUnit.fetch_test_supervisor() do
      {:ok, _sup} -> start_with_ex_unit(protocol_module, options, verify_fn)
      :error -> raise ArgumentError, "can only be called in a test process"
    end
  end

  defp start_with_ex_unit(protocol_module, options, verify_fn) do
    caller = self()

    case InstanceManager.start_instance(caller, protocol_module, options) do
      {:ok, instance} ->
        put_ex_unit_on_exit_callback(protocol_module, instance, verify_fn)
        {:ok, instance}

      {:error, {exception, stacktrace}} when is_exception(exception) ->
        reraise exception, stacktrace

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_ex_unit_on_exit_callback(protocol_module, instance, verify_fn) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(instance) do
        try do
          verify_fn.(instance)
        after
          protocol_module.stop(instance)
        end
      end
    end)
  end

  @doc false
  def stop_instance(protocol_module, instance) do
    ensure_instance_alive!(protocol_module, instance)

    InstanceManager.stop_instance(instance)
  end

  @doc false
  def ensure_instance_alive!(protocol_module, instance) do
    case Process.alive?(instance) do
      true -> :ok
      false -> raise "#{format_instance(protocol_module, instance)} is not running"
    end
  end

  @doc false
  def format_instance(protocol_module, instance) do
    instance_module = Module.concat(protocol_module, Instance)

    "#{inspect(instance_module)} #{inspect(instance)}"
  end

  @doc false
  def raise_start_failure!(protocol_module, options, reason) do
    raise "EXIT when starting #{inspect(protocol_module)} instance#{format_port(options)}:\n\n#{Exception.format_exit(reason)}"
  end

  defp format_port(options) do
    case Keyword.get(options, :port) do
      port when is_integer(port) -> " on port #{port}"
      _no_port -> ""
    end
  end

  @doc false
  def autostart_instance(protocol_module) do
    case InstanceManager.fetch_instance(self(), protocol_module) do
      :error -> protocol_module.start!()
      {:ok, instance} -> instance
    end
  end

  @doc false
  def validate_port!(options) do
    port = Keyword.get(options, :port, 0)

    unless is_integer(port) and port >= 0 and port <= 65_535,
      do: raise(ArgumentError, "expected a port, got: #{inspect(port)}")

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
         RuntimeError.exception(
           "Could not listen to port #{inspect(port)}, because: #{inspect(reason)}"
         )}
    end
  end

  @doc false
  def fetch_instance!(protocol_module) do
    instance_module = Module.concat(protocol_module, Instance)

    case InstanceManager.fetch_instance(self(), protocol_module) do
      :error -> raise "No current #{inspect(instance_module)} running"
      {:ok, instance} -> instance
    end
  end

  @doc false
  def host(options) do
    host = Keyword.get(options, :host)

    unless is_nil(host) or is_binary(host),
      do: raise("Invalid host, got: #{inspect(host)}")

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
  @spec report_error(keyword(), {struct(), TestServer.stacktrace()}) :: :ok
  def report_error(options, {exception, stacktrace}) do
    caller = Keyword.fetch!(options, :caller)

    unless Keyword.get(options, :suppress_warning, false),
      do: IO.warn(Exception.format(:error, exception, stacktrace))

    ExUnit.OnExitHandler.add(caller, make_ref(), fn ->
      reraise exception, stacktrace
    end)

    :ok
  end

  @doc false
  @spec put_tls_options(keyword()) :: keyword()
  @spec put_tls_options(
          keyword(),
          {:rsa, non_neg_integer()} | {:ec, :crypto.ec_named_curve() | :public_key.oid()}
        ) :: keyword()
  def put_tls_options(options, key_type \\ {:rsa, 1_024}) do
    tls_options = Keyword.get(options, :tls, [])

    case Keyword.take(tls_options, [:key, :keyfile]) do
      [] ->
        suite = X509.Test.Suite.new(key_type: key_type)
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
