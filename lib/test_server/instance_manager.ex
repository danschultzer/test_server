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
      |> Keyword.put(:protocol_module, protocol_module)
      |> Keyword.put(:caller, caller)
      |> Keyword.put(:stacktrace, stacktrace)

    child_spec = Supervisor.child_spec({instance_module, options}, restart: :temporary)

    case DynamicSupervisor.start_child(InstanceSupervisor, child_spec) do
      {:ok, instance_pid} ->
        GenServer.call(__MODULE__, {:register, {caller, {protocol_module, instance_pid}}})

      {:error, error} ->
        {:error, error}
    end
  end

  @spec stop_instance(TestServer.instance()) :: :ok | {:error, :not_found}
  def stop_instance(instance) do
    {protocol_module, instance_pid} = instance
    res = DynamicSupervisor.terminate_child(InstanceSupervisor, instance_pid)
    [_first | stacktrace] = TestServer.pruned_stacktrace(protocol_module)

    GenServer.call(__MODULE__, {:stop_instance, instance, stacktrace})

    res
  end

  @spec fetch_instance_by_caller_protocol(pid(), module()) ::
          {:ok, TestServer.instance()} | :error
  def fetch_instance_by_caller_protocol(caller, protocol_module) do
    case GenServer.call(__MODULE__, {:list_instances_by_caller, caller, protocol_module}) do
      [] ->
        :error

      [instance] ->
        {:ok, instance}

      instances ->
        [{m, f, a, _} | _] = TestServer.pruned_stacktrace(protocol_module)

        raise_multiple_instances_error(protocol_module, instances, {m, f, a})
    end
  end

  defp raise_multiple_instances_error(protocol_module, instances, {m, f, a}) do
    formatted_instances =
      instances
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {instance, index} ->
        stacktrace =
          protocol_module
          |> Module.concat(Instance)
          |> apply(:options, [instance])
          |> Keyword.fetch!(:stacktrace)

        """
        ##{index + 1}: #{TestServer.format_instance(instance)}
            #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
      end)

    raise """
    expected exactly one instance to be running, but got multiple instances; pass the instance to #{inspect(m)}.#{f}/#{a + 1}

    #{formatted_instances}
    """
  end

  @spec fetch_instance_entry(TestServer.instance()) ::
          {:ok,
           %{
             caller: pid(),
             instance: {module(), pid()},
             ref: reference(),
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
  def handle_call({:register, {caller, instance}}, _from, state) do
    {_protocol_module, instance_pid} = instance
    monitor = Process.monitor(instance_pid)

    entry = %{
      caller: caller,
      instance: instance,
      ref: monitor,
      exit: nil
    }

    state = %{state | entries: state.entries ++ [entry]}

    {:reply, {:ok, instance}, state}
  end

  def handle_call({:list_instances_by_caller, caller, protocol_module}, _from, state) do
    instances =
      state.entries
      |> Enum.filter(fn
        %{instance: {^protocol_module, _instance_pid}, caller: ^caller, exit: nil} -> true
        %{instance: _instance, caller: _caller, exit: _exit} -> false
      end)
      |> Enum.map(& &1.instance)

    {:reply, instances, state}
  end

  def handle_call({:stop_instance, instance, stacktrace}, _from, state) do
    entries =
      Enum.map(state.entries, fn
        %{instance: ^instance, ref: ref} = entry ->
          Process.demonitor(ref)

          %{entry | exit: %{reason: nil, stacktrace: stacktrace}}

        %{instance: _instance, ref: _ref} = entry ->
          entry
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
  def handle_info({:DOWN, _ref, :process, instance_pid, reason}, state) do
    {[pid_entry], entries} =
      Enum.split_with(state.entries, fn
        %{instance: {_protocol_module, ^instance_pid}} -> true
        %{instance: {_protocol_module, _instance_pid}} -> false
      end)

    entries = entries ++ [%{pid_entry | exit: %{reason: reason, stacktrace: nil}}]
    state = %{state | entries: entries}

    case reason do
      :normal ->
        {:noreply, state}

      :shutdown ->
        {:noreply, state}

      {:shutdown, _} ->
        {:noreply, state}

      reason ->
        Process.exit(pid_entry.caller, reason)

        {:noreply, state}
    end
  end
end
