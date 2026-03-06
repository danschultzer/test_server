defmodule TestServer.SSH do
  @external_resource "lib/test_server/ssh/README.md"
  @moduledoc "lib/test_server/ssh/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias TestServer.SSH

  @spec start(keyword()) :: {:ok, pid()}
  def start(options \\ []) do
    TestServer.start_instance(__MODULE__, options, &verify_instance!/1)
  end

  defp verify_instance!(instance) do
    verify_handlers!(:exec, instance)
    verify_handlers!(:shell, instance)
  end

  defp verify_handlers!(type, instance) do
    instance
    |> SSH.Instance.handlers(type)
    |> Enum.reject(& &1.suspended)
    |> case do
      [] ->
        :ok

      active ->
        raise """
        #{TestServer.format_instance(__MODULE__, instance)} did not receive #{type} requests for these handlers before the test ended:

        #{SSH.Instance.format_handlers(active)}
        """
    end
  end

  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(TestServer.fetch_instance!(__MODULE__))

  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(instance), do: TestServer.stop_instance(__MODULE__, instance)

  @spec address() :: {binary(), :inet.port_number()}
  def address, do: address(TestServer.fetch_instance!(__MODULE__))

  @spec address(pid()) :: {binary(), :inet.port_number()}
  def address(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)
    options = SSH.Instance.get_options(instance)
    {"localhost", Keyword.fetch!(options, :port)}
  end

  @spec exec(keyword()) :: :ok
  def exec(options) when is_list(options) do
    {:ok, instance} = TestServer.autostart_instance(__MODULE__)
    exec(instance, options)
  end

  @spec exec(pid(), keyword()) :: :ok
  def exec(instance, options) when is_pid(instance) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)
    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)
    options = Keyword.put_new(options, :to, &default_exec_handler/2)
    {:ok, _handler} = SSH.Instance.register(instance, {:exec, options, stacktrace})
    :ok
  end

  defp default_exec_handler(_cmd, state), do: {:reply, {0, "", ""}, state}

  @spec shell(keyword()) :: :ok
  def shell(options) when is_list(options) do
    {:ok, instance} = TestServer.autostart_instance(__MODULE__)
    shell(instance, options)
  end

  @spec shell(pid(), keyword()) :: :ok
  def shell(instance, options) when is_pid(instance) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)
    [_first_module_entry | stacktrace] = TestServer.get_pruned_stacktrace(__MODULE__)
    options = Keyword.put_new(options, :to, &default_shell_handler/2)
    {:ok, _handler} = SSH.Instance.register(instance, {:shell, options, stacktrace})
    :ok
  end

  defp default_shell_handler(data, state), do: {:reply, data, state}
end
