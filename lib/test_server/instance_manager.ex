defmodule TestServer.InstanceManager do
  @moduledoc false

  use GenServer

  alias TestServer.InstanceSupervisor

  @type instance_entry :: %{
          caller: pid(),
          instance: {module(), pid()},
          ref: reference(),
          status: :running | {:stopped, TestServer.stacktrace()} | {:exited, term()},
          errors: [{Exception.t(), TestServer.stacktrace()}]
        }

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
        instance = {protocol_module, instance_pid}

        GenServer.call(__MODULE__, {:register, {caller, instance}})

      {:error, error} ->
        {:error, error}
    end
  end

  @spec stop_instance(TestServer.instance()) ::
          {:ok, {:stopped, TestServer.stacktrace()}}
          | {:error, :not_found}
          | {:error, {:stopped, TestServer.stacktrace()}}
          | {:error, {:exited, term()}}
  def stop_instance(instance) do
    {protocol_module, _instance_pid} = instance
    [_first | stacktrace] = TestServer.pruned_stacktrace(protocol_module)

    GenServer.call(__MODULE__, {:stop_instance, instance, stacktrace})
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
        instance_module = Module.concat(protocol_module, Instance)
        options = instance_module.options(instance)
        stacktrace = Keyword.fetch!(options, :stacktrace)

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
          {:ok, instance_entry()} | {:error, :not_found}
  def fetch_instance_entry(instance) do
    GenServer.call(__MODULE__, {:fetch_entry, instance})
  end

  @spec delete_instance_entry(TestServer.instance()) :: :ok
  def delete_instance_entry(instance) do
    GenServer.call(__MODULE__, {:delete_entry, instance})
  end

  @spec add_error(TestServer.instance(), {Exception.t(), TestServer.stacktrace()}) ::
          {:ok, instance_entry()} | {:error, :not_found}
  def add_error(instance, error) do
    GenServer.call(__MODULE__, {:add_error, instance, error})
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
      status: :running,
      errors: []
    }

    state = %{state | entries: state.entries ++ [entry]}

    {:reply, {:ok, instance}, state}
  end

  def handle_call({:list_instances_by_caller, caller, protocol_module}, _from, state) do
    instances =
      state.entries
      |> Enum.filter(fn
        %{instance: {^protocol_module, _instance_pid}, caller: ^caller, status: :running} -> true
        %{instance: _instance, caller: _caller, status: _status} -> false
      end)
      |> Enum.map(& &1.instance)

    {:reply, instances, state}
  end

  def handle_call({:stop_instance, instance, stacktrace}, _from, state) do
    {instance_entries, entries} = Enum.split_with(state.entries, &(&1.instance == instance))

    case instance_entries do
      [] ->
        {:reply, {:error, :not_found}, state}

      [%{status: {:stopped, stacktrace}}] ->
        {:reply, {:error, {:stopped, stacktrace}}, state}

      [%{status: {:exited, reason}}] ->
        {:reply, {:error, {:exited, reason}}, state}

      [%{status: :running} = entry] ->
        {_protocol_module, instance_pid} = entry.instance
        alive? = Process.alive?(instance_pid)
        monitor = entry.ref

        DynamicSupervisor.terminate_child(InstanceSupervisor, instance_pid)

        reason =
          receive do
            {:DOWN, ^monitor, :process, ^instance_pid, reason} -> reason
          end

        case {alive?, reason} do
          {true, :shutdown} ->
            updated_entry = %{entry | status: {:stopped, stacktrace}}
            state = %{state | entries: entries ++ [updated_entry]}

            {:reply, {:ok, updated_entry.status}, state}

          {_, _} ->
            updated_entry = %{entry | status: {:exited, reason}}
            state = %{state | entries: entries ++ [updated_entry]}

            {:reply, {:error, updated_entry.status}, state}
        end
    end
  end

  def handle_call({:fetch_entry, instance}, _from, state) do
    case Enum.find(state.entries, &(&1.instance == instance)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :running} = entry ->
        {entry, state} = synchronize_entry(entry, state)

        {:reply, {:ok, entry}, state}

      %{status: _other} = entry ->
        {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:delete_entry, instance}, _from, state) do
    entries = Enum.reject(state.entries, &(&1.instance == instance))

    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:add_error, instance, error}, _from, state) do
    case Enum.find_index(state.entries, &(&1.instance == instance)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        entry = Enum.at(state.entries, index)
        updated_entry = %{entry | errors: entry.errors ++ [error]}
        entries = List.replace_at(state.entries, index, updated_entry)

        {:reply, {:ok, updated_entry}, %{state | entries: entries}}
    end
  end

  defp synchronize_entry(
         %{status: :running, instance: {_protocol_module, instance_pid}, ref: monitor} = entry,
         state
       ) do
    case Process.alive?(instance_pid) do
      true ->
        {entry, state}

      false ->
        receive do
          {:DOWN, ^monitor, :process, ^instance_pid, reason} ->
            {[entry], entries} = Enum.split_with(state.entries, &(&1.ref == monitor))
            updated_entry = %{entry | status: {:exited, reason}}

            {updated_entry, %{state | entries: entries ++ [updated_entry]}}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {ref_entries, entries} = Enum.split_with(state.entries, &(&1.ref == ref))

    ref_entries =
      case ref_entries do
        [] ->
          []

        [%{status: :running} = entry] ->
          abnormal_exit?(reason) && Process.exit(entry.caller, reason)

          [%{entry | status: {:exited, reason}}]
      end

    {:noreply, %{state | entries: entries ++ ref_entries}}
  end

  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _}), do: false
  defp abnormal_exit?(_), do: true
end
