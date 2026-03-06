defmodule TestServer.SSH do
  @moduledoc false

  alias TestServer.{InstanceManager, SSH}

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

    case InstanceManager.start_instance(caller, SSH.Instance.child_spec(options)) do
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
        verify_handlers!(:exec, instance)
        verify_handlers!(:shell, instance)
        stop(instance)
      end
    end)
  end

  defp verify_handlers!(type, instance) do
    handlers_fn =
      if type == :exec, do: &SSH.Instance.exec_handlers/1, else: &SSH.Instance.shell_handlers/1

    instance
    |> handlers_fn.()
    |> Enum.reject(& &1.suspended)
    |> case do
      [] ->
        :ok

      active ->
        raise """
        #{SSH.Instance.format_instance(instance)} did not receive #{type} requests for these handlers before the test ended:

        #{SSH.Instance.format_handlers(active)}
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
    options = SSH.Instance.get_options(instance)
    {"localhost", Keyword.fetch!(options, :port)}
  end

  @spec exec(keyword()) :: :ok
  def exec(options) when is_list(options) do
    {:ok, instance} = autostart()
    exec(instance, options)
  end

  @spec exec(pid(), keyword()) :: :ok
  def exec(instance, options) when is_pid(instance) and is_list(options) do
    instance_alive!(instance)
    [_first_module_entry | stacktrace] = get_stacktrace()
    options = Keyword.put_new(options, :to, &default_exec_handler/2)
    {:ok, _handler} = SSH.Instance.register(instance, {:exec, options, stacktrace})
    :ok
  end

  defp default_exec_handler(_cmd, state), do: {:reply, {0, "", ""}, state}

  @spec shell(keyword()) :: :ok
  def shell(options) when is_list(options) do
    {:ok, instance} = autostart()
    shell(instance, options)
  end

  @spec shell(pid(), keyword()) :: :ok
  def shell(instance, options) when is_pid(instance) and is_list(options) do
    instance_alive!(instance)
    [_first_module_entry | stacktrace] = get_stacktrace()
    options = Keyword.put_new(options, :to, &default_shell_handler/2)
    {:ok, _handler} = SSH.Instance.register(instance, {:shell, options, stacktrace})
    :ok
  end

  defp default_shell_handler(data, state), do: {:reply, data, state}

  defp autostart do
    case fetch_instance() do
      :error -> start()
      {:ok, instance} -> {:ok, instance}
    end
  end

  defp fetch_instance! do
    case fetch_instance() do
      :error -> raise "No current #{inspect(SSH.Instance)} running"
      {:ok, instance} -> instance
    end
  end

  defp fetch_instance do
    instances = InstanceManager.get_by_caller(self()) || []
    ssh_instances = Enum.filter(instances, &ssh_instance?/1)

    case ssh_instances do
      [] ->
        :error

      [instance] ->
        {:ok, instance}

      [_first | _rest] = multiple ->
        [{m, f, a, _} | _] = get_stacktrace()

        formatted =
          multiple
          |> Enum.map(&{&1, SSH.Instance.get_options(&1)})
          |> Enum.with_index()
          |> Enum.map_join("\n\n", fn {{instance, options}, index} ->
            """
            ##{index + 1}: #{SSH.Instance.format_instance(instance)}
                #{Enum.map_join(options[:stacktrace], "\n    ", &Exception.format_stacktrace_entry/1)}
            """
          end)

        raise """
        Multiple #{inspect(SSH.Instance)}'s running, please pass instance to `#{inspect(m)}.#{f}/#{a}`.

        #{formatted}
        """
    end
  end

  defp ssh_instance?(pid) do
    SSH.Instance.get_options(pid)[:protocol] == :ssh
  rescue
    _ -> false
  end

  defp instance_alive!(instance) do
    unless Process.alive?(instance),
      do: raise("#{SSH.Instance.format_instance(instance)} is not running")
  end

  defp raise_start_failure({:error, {{:EXIT, reason}, _spec}}) do
    raise_start_failure({:error, reason})
  end

  defp raise_start_failure({:error, error}) do
    raise """
    EXIT when starting #{inspect(SSH.Instance)}:

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
