defmodule TestServer do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @type instance :: pid()
  @type stacktrace :: list()

  alias TestServer.InstanceManager

  @doc false
  def get_pruned_stacktrace(calling_module) do
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
        put_ex_unit_on_exit_callback(instance, verify_fn)
        {:ok, instance}

      {:error, error} ->
        raise_start_failure(protocol_module, error)
    end
  end

  defp put_ex_unit_on_exit_callback(instance, verify_fn) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(instance) do
        verify_fn.(instance)
        InstanceManager.stop_instance(instance)
      end
    end)
  end

  defp raise_start_failure(_calling_module, {:EXIT, reason}) do
    raise_start_failure(nil, reason)
  end

  defp raise_start_failure(calling_module, error) do
    raise "EXIT when starting #{inspect(calling_module)} instance:\n\n#{Exception.format_exit(error)}"
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
  def autostart_instance(protocol_module) do
    case InstanceManager.fetch_instance(self(), protocol_module) do
      :error -> protocol_module.start()
      {:ok, instance} -> {:ok, instance}
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
end
