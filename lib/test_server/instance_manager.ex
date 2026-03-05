defmodule TestServer.InstanceManager do
  @moduledoc false

  use GenServer

  alias TestServer.InstanceSupervisor

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @spec start_instance(pid(), module(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_instance(caller, protocol_module, options) do
    [_first | stacktrace] = TestServer.get_pruned_stacktrace(protocol_module)

    instance_module = Module.concat(protocol_module, Instance)

    options =
      options
      |> Keyword.put_new(:caller, caller)
      |> Keyword.put_new(:stacktrace, stacktrace)

    case DynamicSupervisor.start_child(InstanceSupervisor, instance_module.child_spec(options)) do
      {:ok, instance} ->
        GenServer.call(__MODULE__, {:register, {caller, protocol_module, instance}})

      {:error, error} ->
        {:error, error}
    end
  end

  @spec stop_instance(pid()) :: :ok | {:error, :not_found}
  def stop_instance(instance) do
    res = DynamicSupervisor.terminate_child(InstanceSupervisor, instance)
    GenServer.call(__MODULE__, {:remove, instance})

    res
  end

  @spec fetch_instance(pid(), module()) :: {:ok, pid()} | :error
  def fetch_instance(caller, protocol_module) do
    case GenServer.call(__MODULE__, {:get_by_caller, caller, protocol_module}) do
      [] -> :error
      [instance] -> {:ok, instance}
      instances -> raise_multiple_instances_error(instances, protocol_module)
    end
  end

  defp raise_multiple_instances_error(instances, protocol_module) do
    [{m, f, a, _} | _] = TestServer.get_pruned_stacktrace(protocol_module)

    formatted_instances =
      instances
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {instance, index} ->
        options = GenServer.call(instance, :options)

        """
        ##{index + 1}: #{inspect(instance)}
            #{Enum.map_join(options[:stacktrace], "\n    ", &Exception.format_stacktrace_entry/1)}
        """
      end)

    raise """
    Multiple instances running, please pass instance to `#{inspect(m)}.#{f}/#{a}`.

    #{formatted_instances}
    """
  end

  @impl true
  def init(_options) do
    {:ok, %{instances: []}}
  end

  @impl true
  def handle_call({:register, {caller, protocol_module, instance}}, _from, state) do
    entry = %{caller: caller, instance: instance, protocol_module: protocol_module}
    state = %{state | instances: state.instances ++ [entry]}

    {:reply, {:ok, instance}, state}
  end

  def handle_call({:get_by_caller, caller, protocol_module}, _from, state) do
    instances =
      state.instances
      |> Enum.filter(&(&1.caller == caller and &1.protocol_module == protocol_module))
      |> Enum.map(& &1.instance)

    {:reply, instances, state}
  end

  def handle_call({:alive?, instance}, _from, state) do
    instance = Enum.find(state.instances, &(&1.instance == instance))

    {:reply, not is_nil(instance)}
  end

  def handle_call({:remove, instance}, _from, state) do
    state = %{state | instances: Enum.reject(state.instances, &(&1.instance == instance))}

    {:reply, :ok, state}
  end
end
