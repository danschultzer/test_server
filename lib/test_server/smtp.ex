defmodule TestServer.SMTP do
  @moduledoc false

  alias TestServer.{InstanceManager, SMTP}

  @spec start(keyword()) :: {:ok, pid()}
  def start(options \\ []) do
    case ExUnit.fetch_test_supervisor() do
      {:ok, _sup} -> start_with_ex_unit(options)
      :error -> raise ArgumentError, "can only be called in a test process"
    end
  end

  defp start_with_ex_unit(options) do
    [_first_module_entry | stacktrace] = get_stacktrace()
    caller = self()

    options =
      options
      |> Keyword.put_new(:caller, caller)
      |> Keyword.put_new(:stacktrace, stacktrace)

    case InstanceManager.start_instance(caller, SMTP.Instance.child_spec(options)) do
      {:ok, instance} ->
        put_ex_unit_on_exit_callback(instance)
        {:ok, instance}

      {:error, error} ->
        raise_start_failure({:error, error})
    end
  end

  defp put_ex_unit_on_exit_callback(instance) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(instance) do
        verify_handlers!(instance)
        stop(instance)
      end
    end)
  end

  defp verify_handlers!(instance) do
    instance
    |> SMTP.Instance.handlers()
    |> Enum.reject(& &1.suspended)
    |> case do
      [] ->
        :ok

      active ->
        raise """
        #{SMTP.Instance.format_instance(instance)} did not receive mail for these handlers before the test ended:

        #{SMTP.Instance.format_handlers(active)}
        """
    end
  end

  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(instance) do
    instance_alive!(instance)
    InstanceManager.stop_instance(instance)
  end

  @spec address() :: {binary(), :inet.port_number()}
  def address, do: address(fetch_instance!())

  @spec address(pid()) :: {binary(), :inet.port_number()}
  def address(instance) do
    instance_alive!(instance)
    options = SMTP.Instance.get_options(instance)
    {"localhost", Keyword.fetch!(options, :port)}
  end

  @spec receive_mail(keyword()) :: :ok
  def receive_mail(options) when is_list(options) do
    {:ok, instance} = autostart()
    receive_mail(instance, options)
  end

  @spec receive_mail(pid(), keyword()) :: :ok
  def receive_mail(instance, options) when is_pid(instance) and is_list(options) do
    instance_alive!(instance)
    [_first_module_entry | stacktrace] = get_stacktrace()
    {:ok, _handler} = SMTP.Instance.register(instance, {options, stacktrace})
    :ok
  end

  @spec x509_suite() :: term()
  def x509_suite, do: x509_suite(fetch_instance!())

  @spec x509_suite(pid()) :: term()
  def x509_suite(instance) do
    instance_alive!(instance)
    GenServer.call(instance, :x509_suite)
  end

  defp autostart do
    case fetch_instance() do
      :error -> start()
      {:ok, instance} -> {:ok, instance}
    end
  end

  defp fetch_instance! do
    case fetch_instance() do
      :error -> raise "No current #{inspect(SMTP.Instance)} running"
      {:ok, instance} -> instance
    end
  end

  defp fetch_instance do
    instances = InstanceManager.get_by_caller(self()) || []
    smtp_instances = Enum.filter(instances, &smtp_instance?/1)

    case smtp_instances do
      [] ->
        :error

      [instance] ->
        {:ok, instance}

      [_first | _rest] = multiple ->
        [{m, f, a, _} | _] = get_stacktrace()

        formatted =
          multiple
          |> Enum.map(&{&1, SMTP.Instance.get_options(&1)})
          |> Enum.with_index()
          |> Enum.map_join("\n\n", fn {{instance, options}, index} ->
            """
            ##{index + 1}: #{SMTP.Instance.format_instance(instance)}
                #{Enum.map_join(options[:stacktrace], "\n    ", &Exception.format_stacktrace_entry/1)}
            """
          end)

        raise """
        Multiple #{inspect(SMTP.Instance)}'s running, please pass instance to `#{inspect(m)}.#{f}/#{a}`.

        #{formatted}
        """
    end
  end

  defp smtp_instance?(pid) do
    SMTP.Instance.get_options(pid)[:protocol] == :smtp
  rescue
    _ -> false
  end

  defp instance_alive!(instance) do
    unless Process.alive?(instance),
      do: raise("#{SMTP.Instance.format_instance(instance)} is not running")
  end

  defp raise_start_failure({:error, {{:EXIT, reason}, _spec}}) do
    raise_start_failure({:error, reason})
  end

  defp raise_start_failure({:error, error}) do
    raise """
    EXIT when starting #{inspect(SMTP.Instance)}:

    #{Exception.format_exit(error)}
    """
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

  defp prune_stacktrace([{__MODULE__, _, _, _} | t]), do: prune_stacktrace(t)
  defp prune_stacktrace([{ExUnit.Assertions, _, _, _} | t]), do: prune_stacktrace(t)
  defp prune_stacktrace([{ExUnit.Runner, _, _, _} | _]), do: []
  defp prune_stacktrace([h | t]), do: [h | prune_stacktrace(t)]
  defp prune_stacktrace([]), do: []
end
