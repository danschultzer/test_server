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
  def start_instance(protocol_module, options, verify_instance_fn) do
    case ExUnit.fetch_test_supervisor() do
      {:ok, _sup} ->
        start_with_ex_unit(protocol_module, options, verify_instance_fn)

      :error ->
        raise ArgumentError,
              "cannot start a #{inspect(protocol_module)} instance outside the test process"
    end
  end

  defp start_with_ex_unit(protocol_module, options, verify_instance_fn) do
    caller = self()

    case InstanceManager.start_instance(caller, protocol_module, options) do
      {:ok, instance} ->
        put_ex_unit_on_exit_callback(protocol_module, instance, verify_instance_fn)

        {:ok, instance}

      {:error, {exception, stacktrace}} when is_exception(exception) ->
        reraise exception, stacktrace

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_ex_unit_on_exit_callback(protocol_module, instance, verify_instance_fn) do
    Process.put({:test_process, __MODULE__}, true)

    ExUnit.Callbacks.on_exit({TestServer, instance}, fn ->
      try do
        assert_instance_alive!(protocol_module, instance)

        try do
          verify_instance_fn.(instance)
        after
          protocol_module.stop(instance)
        end
      after
        InstanceManager.delete_instance_entry(instance)
      end
    end)
  end

  @doc false
  def stop_instance(protocol_module, instance) do
    assert_instance_alive!(protocol_module, instance)

    case InstanceManager.stop_instance(instance, protocol_module) do
      :ok ->
        Process.get({:test_process, __MODULE__}) &&
          ExUnit.Callbacks.on_exit({TestServer, instance}, fn ->
            InstanceManager.delete_instance_entry(instance)
          end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def assert_instance_alive!(protocol_module, instance) do
    case InstanceManager.fetch_instance_entry(instance) do
      {:error, :not_found} ->
        raise "expected #{format_instance(protocol_module, instance)} to be an TestServer managed instance"

      {:ok, %{exit: nil}} ->
        :ok

      {:ok, %{exit: %{reason: nil, stacktrace: stacktrace}}} when is_list(stacktrace) ->
        raise """
        expected #{format_instance(protocol_module, instance)} to be running, but it was stopped at:

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """

      {:ok, %{exit: %{reason: reason, stacktrace: nil}}} ->
        raise """
        expected #{format_instance(protocol_module, instance)} to be running, but it exited with reason:

        #{Exception.format_exit(reason)}
        """
    end
  end

  @doc false
  def format_instance(protocol_module, instance) do
    instance_module = Module.concat(protocol_module, Instance)

    "#{inspect(instance_module)} #{inspect(instance)}"
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
  def fetch_instance!(protocol_module) do
    instance_module = Module.concat(protocol_module, Instance)

    case InstanceManager.fetch_instance(self(), protocol_module) do
      :error -> raise "no current #{inspect(instance_module)} is running"
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
