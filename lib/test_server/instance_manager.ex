defmodule TestServer.InstanceManager do
  @moduledoc false

  use GenServer

  alias TestServer.InstanceSupervisor

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def start_instance(caller, child_spec) do
    case DynamicSupervisor.start_child(InstanceSupervisor, child_spec) do
      {:ok, instance} -> GenServer.call(__MODULE__, {:register, {caller, instance}})
      {:error, error} -> {:error, error}
    end
  end

  @spec stop_instance(pid()) :: :ok | {:error, :not_found}
  def stop_instance(instance) do
    res = DynamicSupervisor.terminate_child(InstanceSupervisor, instance)
    GenServer.call(__MODULE__, {:remove, instance})

    res
  end

  @spec get_by_caller(pid()) :: nil | [pid()]
  def get_by_caller(caller) do
    GenServer.call(__MODULE__, {:get_by_caller, caller})
  end

  @spec fetch_instance(pid(), atom(), module()) :: {:ok, pid()} | :error
  def fetch_instance(caller, protocol, calling_module) do
    instances =
      caller
      |> get_by_caller()
      |> List.wrap()
      |> Enum.filter(&instance_protocol?(&1, protocol))

    case instances do
      [] ->
        :error

      [instance] ->
        {:ok, instance}

      [_ | _] = instances ->
        [{m, f, a, _} | _] = get_stacktrace(calling_module)

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
  end

  @spec get_stacktrace(module()) :: list()
  def get_stacktrace(calling_module) do
    {:current_stacktrace, [{Process, :info, _, _} | stacktrace]} =
      Process.info(self(), :current_stacktrace)

    first_module_entry =
      stacktrace
      |> Enum.reverse()
      |> Enum.find(fn {mod, _, _, _} -> mod == calling_module end)

    [first_module_entry] ++ prune_stacktrace(stacktrace, calling_module)
  end

  defp instance_protocol?(pid, protocol) do
    GenServer.call(pid, :options)[:protocol] == protocol
  rescue
    _ -> false
  end

  defp prune_stacktrace([{__MODULE__, _, _, _} | t], mod), do: prune_stacktrace(t, mod)
  defp prune_stacktrace([{mod, _, _, _} | t], mod), do: prune_stacktrace(t, mod)
  defp prune_stacktrace([{ExUnit.Assertions, _, _, _} | t], mod), do: prune_stacktrace(t, mod)
  defp prune_stacktrace([{ExUnit.Runner, _, _, _} | _], _mod), do: []
  defp prune_stacktrace([h | t], mod), do: [h | prune_stacktrace(t, mod)]
  defp prune_stacktrace([], _mod), do: []

  @impl true
  def init(_options) do
    {:ok, %{instances: []}}
  end

  @impl true
  def handle_call({:register, {caller, instance}}, _from, state) do
    state = %{state | instances: state.instances ++ [%{caller: caller, instance: instance}]}

    {:reply, {:ok, instance}, state}
  end

  def handle_call({:get_by_caller, caller}, _from, state) do
    instance =
      case Enum.filter(state.instances, &(&1.caller == caller)) do
        [] -> nil
        instances -> Enum.map(instances, & &1.instance)
      end

    {:reply, instance, state}
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
