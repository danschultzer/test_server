defmodule TestServer.InstanceManager do
  @moduledoc false

  use GenServer

  alias TestServer.InstanceSupervisor

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @spec start_instance(pid(), module(), keyword()) ::
          {:ok, TestServer.instance()} | {:error, term()}
  def start_instance(caller, protocol_module, options) do
    [_first | stacktrace] = TestServer.pruned_stacktrace(protocol_module)

    instance_module = Module.concat(protocol_module, Instance)

    options =
      options
      |> Keyword.put_new(:caller, caller)
      |> Keyword.put_new(:stacktrace, stacktrace)

    child_spec = Supervisor.child_spec({instance_module, options}, restart: :temporary)

    case DynamicSupervisor.start_child(InstanceSupervisor, child_spec) do
      {:ok, instance} ->
        GenServer.call(__MODULE__, {:register, {caller, protocol_module, instance}})

      {:error, error} ->
        {:error, error}
    end
  end

  @spec stop_instance(TestServer.instance(), module()) :: :ok | {:error, :not_found}
  def stop_instance(instance, protocol_module) do
    res = DynamicSupervisor.terminate_child(InstanceSupervisor, instance)
    [_first | stacktrace] = TestServer.pruned_stacktrace(protocol_module)

    GenServer.call(__MODULE__, {:stop_instance, instance, stacktrace})

    res
  end

  @spec fetch_instance(pid(), module()) :: {:ok, TestServer.instance()} | :error
  def fetch_instance(caller, protocol_module) do
    case GenServer.call(__MODULE__, {:list_instances_by_caller, caller, protocol_module}) do
      [] -> :error
      [instance] -> {:ok, instance}
      instances -> raise_multiple_instances_error(instances, protocol_module)
    end
  end

  defp raise_multiple_instances_error(instances, protocol_module) do
    [{m, f, a, _} | _] = TestServer.pruned_stacktrace(protocol_module)

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
    multiple instances are running; pass the instance to #{inspect(m)}.#{f}/#{a + 1}

    #{formatted_instances}
    """
  end

  @spec fetch_instance_entry(pid()) ::
          {:ok,
           %{
             caller: pid(),
             instance: pid(),
             monitor: reference(),
             protocol_module: module(),
             exit: nil | %{reason: nil | term(), stacktrace: nil | TestServer.stacktrace()}
           }}
          | {:error, :not_found}
  def fetch_instance_entry(instance) do
    GenServer.call(__MODULE__, {:fetch_entry, instance})
  end

  @spec delete_instance_entry(TestServer.instance()) :: :ok
  def delete_instance_entry(instance) do
    GenServer.call(__MODULE__, {:delete_entry, instance})
  end

  @impl true
  def init(_options) do
    {:ok, %{entries: []}}
  end

  @impl true
  def handle_call({:register, {caller, protocol_module, instance}}, _from, state) do
    monitor = Process.monitor(instance)

    entry = %{
      caller: caller,
      instance: instance,
      monitor: monitor,
      protocol_module: protocol_module,
      exit: nil
    }

    state = %{state | entries: state.entries ++ [entry]}

    {:reply, {:ok, instance}, state}
  end

  def handle_call({:list_instances_by_caller, caller, protocol_module}, _from, state) do
    instances =
      state.entries
      |> Enum.filter(fn entry ->
        entry.caller == caller and
          entry.protocol_module == protocol_module and
          is_nil(entry.exit)
      end)
      |> Enum.map(& &1.instance)

    {:reply, instances, state}
  end

  def handle_call({:stop_instance, instance, stacktrace}, _from, state) do
    entries =
      Enum.map(state.entries, fn entry ->
        case entry.instance == instance do
          true ->
            Process.demonitor(entry.monitor)

            %{entry | exit: %{reason: nil, stacktrace: stacktrace}}

          false ->
            entry
        end
      end)

    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:fetch_entry, instance}, _from, state) do
    case Enum.find(state.entries, &(&1.instance == instance)) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:delete_entry, instance}, _from, state) do
    entries = Enum.reject(state.entries, &(&1.instance == instance))

    {:reply, :ok, %{state | entries: entries}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, instance, reason}, state) do
    entries =
      Enum.map(state.entries, fn entry ->
        case entry.instance == instance do
          true -> %{entry | exit: %{reason: reason, stacktrace: nil}}
          false -> entry
        end
      end)

    state = %{state | entries: entries}

    case reason do
      :normal ->
        {:noreply, state}

      :shutdown ->
        {:noreply, state}

      {:shutdown, _} ->
        {:noreply, state}

      reason ->
        entry = Enum.find(state.entries, &(&1.instance == instance))

        Process.exit(entry.caller, reason)

        {:noreply, state}
    end
  end
end
