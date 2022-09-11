defmodule TestServer.InstanceManager do
  @moduledoc false

  use GenServer

  alias TestServer.{Instance, InstanceSupervisor}

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def start_instance(options) do
    options = Keyword.put_new(options, :caller, self())
    caller = Keyword.fetch!(options, :caller)

    case DynamicSupervisor.start_child(InstanceSupervisor, Instance.child_spec(options)) do
      {:ok, instance} -> GenServer.call(__MODULE__, {:register, {caller, instance}})
      {:error, error} -> {:error, error}
    end
  end

  @spec stop_instance(pid()) :: :ok | {:error, :not_found}
  def stop_instance(instance) do
    :ok = TestServer.Plug.Cowboy.stop(Instance.get_options(instance))
    res = DynamicSupervisor.terminate_child(InstanceSupervisor, instance)
    GenServer.cast(__MODULE__, {:remove, {instance}})

    res
  end

  def get_by_caller(caller) do
    GenServer.call(__MODULE__, {:get_by_caller, caller})
  end

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
      case Enum.find(state.instances, &(&1.caller == caller)) do
        nil -> nil
        %{instance: instance} -> instance
      end

    {:reply, instance, state}
  end

  @impl true
  def handle_cast({:remove, instance}, state) do
    state = %{state | instances: Enum.reject(state.instances, &(&1.instance == instance))}

    {:noreply, state}
  end
end
