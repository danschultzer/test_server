defmodule TestServer.InetDB do
  @moduledoc false

  use GenServer

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @spec add_host(TestServer.ip_address(), binary(), :inet | :inet6) ::
          :ok | {:error, [:inet.ip_address()]}
  def add_host(ip, host, ipfamily) do
    GenServer.call(__MODULE__, {:add_host, ip, host, ipfamily})
  end

  @impl true
  def init(_options) do
    Process.flag(:trap_exit, true)

    {:ok, %{entries: [], lookup: nil}}
  end

  @impl true
  def handle_call({:add_host, ip, name, ipfamily}, {caller_pid, _tag}, state) do
    state = cleanup_dead_entries(state)
    name = String.to_charlist(name)
    state = ensure_file_lookup(state)

    case add_host(caller_pid, ip, ipfamily, name, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, ips} -> {:reply, {:error, ips}, reset_inet_lookup(state)}
    end
  end

  defp cleanup_dead_entries(state) do
    Enum.reduce(state.entries, state, fn %{ref: monitor, caller: caller_pid}, state ->
      case Process.alive?(caller_pid) do
        true -> state
        false -> remove_entry(monitor, state)
      end
    end)
  end

  defp remove_entry(monitor, state) do
    Process.demonitor(monitor, [:flush])

    {removed, entries} = Enum.split_with(state.entries, &(&1.ref == monitor))

    Enum.each(removed, fn
      %{owned?: true, ip: ip, name: name} ->
        case Enum.any?(entries, &(&1.ip == ip and &1.name == name)) do
          true -> :ok
          false -> delete_host_name(ip, name)
        end

      %{owned?: false} ->
        :ok
    end)

    %{state | entries: entries}
  end

  defp delete_host_name(ip, name) do
    case List.delete(host_names(ip), name) do
      [] -> :ok = :inet_db.del_host(ip)
      names -> :ok = :inet_db.add_host(ip, names)
    end
  end

  defp ensure_file_lookup(%{lookup: nil} = state) do
    lookup = :inet_db.res_option(:lookup)

    :inet_db.set_lookup([:file | List.delete(lookup, :file)])

    %{state | lookup: lookup}
  end

  defp ensure_file_lookup(%{lookup: _lookup} = state), do: state

  defp add_host(caller_pid, ip, ipfamily, name, state) do
    case List.delete(host_ips(name, ipfamily), ip) do
      [] ->
        names = host_names(ip)
        name_key = :inet_db.tolower(name)
        existing_name = Enum.find(names, &(:inet_db.tolower(&1) == name_key))
        name = existing_name || name

        owned? =
          case Enum.find(state.entries, &(&1.ip == ip and &1.name == name)) do
            nil -> is_nil(existing_name)
            entry -> entry.owned?
          end

        case existing_name do
          nil -> :inet_db.add_host(ip, [name | names])
          _name -> :ok
        end

        entry = %{
          ref: Process.monitor(caller_pid),
          ip: ip,
          name: name,
          caller: caller_pid,
          owned?: owned?
        }

        {:ok, %{state | entries: [entry | state.entries]}}

      ips ->
        {:error, ips}
    end
  end

  defp host_ips(name, ipfamily) do
    case :inet_hosts.gethostbyname(name, ipfamily) do
      {:ok, {:hostent, _name, _aliases, _family, _length, ips}} -> ips
      {:error, _} -> []
    end
  end

  defp host_names(ip) do
    Enum.find_value(:inet_db.get_rc(), [], fn
      {:host, ^ip, names} -> names
      _entry -> nil
    end)
  end

  defp reset_inet_lookup(%{entries: [], lookup: nil} = state), do: state

  defp reset_inet_lookup(%{entries: [], lookup: lookup} = state) do
    :ok = :inet_db.set_lookup(lookup)

    %{state | lookup: nil}
  end

  defp reset_inet_lookup(%{entries: _} = state), do: state

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, monitor |> remove_entry(state) |> reset_inet_lookup()}
  end

  @impl true
  def terminate(_reason, state) do
    state.entries
    |> Enum.map(& &1.ref)
    |> Enum.reduce(state, &remove_entry/2)
    |> reset_inet_lookup()

    :ok
  end
end
