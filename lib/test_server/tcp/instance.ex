defmodule TestServer.TCP.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.TCP.Server

  @send_timeout 100

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(TestServer.instance(), {:connection, TestServer.stacktrace()}) ::
          {:ok, %{ref: TestServer.TCP.connection_ref()}}
  def register(instance, {:connection, stacktrace}) do
    GenServer.call(instance, {:register, {:connection, stacktrace}})
  end

  @spec register(
          TestServer.instance(),
          {:handle, {TestServer.TCP.connection_ref(), keyword(), TestServer.stacktrace()}}
        ) :: {:ok, map()}
  def register(instance, {:handle, {connection_ref, options, stacktrace}}) do
    options[:to] && ensure_function!(options[:to])
    options[:match] && ensure_function!(options[:match])

    GenServer.call(instance, {:register, {:handle, {connection_ref, options, stacktrace}}})
  end

  defp ensure_function!(fun) when is_function(fun), do: :ok
  defp ensure_function!(fun), do: raise(BadFunctionError, term: fun)

  @spec dispatch(TestServer.instance(), {:connection, pid(), :gen_tcp.socket()}) ::
          {:ok, map()} | {:error, :not_found}
  def dispatch(instance, {:connection, owner, socket}) do
    GenServer.call(instance, {:dispatch, {:connection, {owner, socket}}})
  end

  @spec dispatch(TestServer.instance(), {:handle, pid(), TestServer.TCP.data()}) ::
          {:reply, TestServer.TCP.data()}
          | :ok
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:handle, owner, data}) do
    GenServer.call(instance, {:dispatch, {:handle, {owner, data}}})
  end

  @spec dispatch(
          TestServer.TCP.connection(),
          {:send, keyword(), TestServer.stacktrace()}
        ) :: :ok | {:error, term()}
  def dispatch({instance, _connection_ref} = connection, {:send, options, stacktrace}) do
    options[:to] && ensure_function!(options[:to])

    GenServer.call(instance, {:dispatch, {:send, {connection, options, stacktrace}}})
  end

  @spec options(TestServer.instance()) :: keyword()
  def options(instance) do
    GenServer.call(instance, :options)
  end

  @spec connections(TestServer.instance()) :: [map()]
  def connections(instance) do
    GenServer.call(instance, :connections)
  end

  @spec handlers(TestServer.instance()) :: [map()]
  def handlers(instance) do
    GenServer.call(instance, :handlers)
  end

  @spec format_handlers([map()]) :: binary()
  def format_handlers(handlers) do
    handlers
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {handler, index} ->
      """
      ##{index + 1}: #{inspect(handler.to)}
          #{Enum.map_join(handler.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
      """
    end)
  end

  @spec format_connections([map()]) :: binary()
  def format_connections(connections) do
    connections
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {connection, index} ->
      """
      ##{index + 1}: #{inspect(connection.ref)}
          #{Enum.map_join(connection.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
      """
    end)
  end

  @impl true
  def init(options) do
    case Server.start(self(), options) do
      {:ok, options} ->
        {:ok, %{options: options, handlers: [], connections: [], sends: []}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register, {:connection, stacktrace}}, _from, state) do
    connection = %{
      ref: make_ref(),
      stacktrace: stacktrace,
      owner: nil,
      socket: nil,
      state: %{}
    }

    {:reply, {:ok, connection}, %{state | connections: state.connections ++ [connection]}}
  end

  def handle_call(
        {:register, {:handle, {connection_ref, options, stacktrace}}},
        _from,
        state
      ) do
    handler = %{
      ref: make_ref(),
      connection_ref: connection_ref,
      match: Keyword.get(options, :match),
      to: Keyword.fetch!(options, :to),
      stacktrace: stacktrace,
      suspended: false,
      received: []
    }

    {:reply, {:ok, handler}, %{state | handlers: state.handlers ++ [handler]}}
  end

  def handle_call({:dispatch, {:connection, {owner, socket}}}, _from, state) do
    case find_available_connection(state.connections) do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        connection = %{Enum.at(state.connections, index) | owner: owner, socket: socket}
        connections = List.replace_at(state.connections, index, connection)

        state = flush_sends(connection, %{state | connections: connections})

        {:reply, {:ok, connection}, state}
    end
  end

  def handle_call({:dispatch, {:handle, {owner, data}}}, _from, state) do
    case Enum.find(state.connections, &(&1.owner == owner)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      connection ->
        {res, state} = run_handlers(data, connection, state)
        {res, state} = update_connection_response(res, owner, state)

        {:reply, res, state}
    end
  end

  def handle_call(
        {:dispatch, {:send, {{_instance, connection_ref}, options, stacktrace}}},
        from,
        state
      ) do
    case Enum.find(state.connections, &(&1.ref == connection_ref)) do
      %{owner: nil} ->
        Process.send_after(self(), {:send_timeout, from}, @send_timeout)

        {:noreply, %{state | sends: state.sends ++ [{connection_ref, from, options, stacktrace}]}}

      %{owner: _owner} = connection ->
        {result, state} = do_send(connection, options, stacktrace, state)

        {:reply, result, state}

      nil ->
        {:reply, {:error, :einval}, state}
    end
  end

  def handle_call(option, _from, state) when option in [:connections, :handlers, :options] do
    {:reply, Map.fetch!(state, option), state}
  end

  @impl true
  def handle_info({:send_timeout, from}, state) do
    case List.keytake(state.sends, from, 1) do
      {_send, sends} ->
        GenServer.reply(from, {:error, :enotconn})
        {:noreply, %{state | sends: sends}}

      nil ->
        {:noreply, state}
    end
  end

  defp find_available_connection(connections) do
    Enum.find_index(connections, &(not is_nil(&1.ref) and is_nil(&1.owner))) ||
      Enum.find_index(connections, &(is_nil(&1.ref) and is_nil(&1.owner)))
  end

  defp flush_sends(connection, state) do
    {connection_sends, sends} = Enum.split_with(state.sends, &(elem(&1, 0) == connection.ref))

    state = %{state | sends: sends}

    Enum.reduce(connection_sends, state, fn {_ref, from, options, stacktrace}, state ->
      {result, state} = do_send(connection, options, stacktrace, state)

      GenServer.reply(from, result)

      state
    end)
  end

  defp run_handlers(data, connection, state) do
    state.handlers
    |> fetch_match_index([data, connection.state], fn
      %{connection_ref: ref, suspended: suspended} ->
        ref == connection.ref and not suspended
    end)
    |> case do
      {:error, :not_found} ->
        {{:error, :not_found}, state}

      {:error, {error, stacktrace}} ->
        {{:error, {error, stacktrace}}, state}

      {:ok, index} ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.handlers, index)

        result = try_run_handler(handler, data, connection.state, stacktrace)

        handlers =
          List.update_at(state.handlers, index, fn handler ->
            %{handler | suspended: true, received: handler.received ++ [data]}
          end)

        {result, %{state | handlers: handlers}}
    end
  end

  defp fetch_match_index(items, args, callback) do
    items
    |> Enum.find_index(fn %{match: match} = item ->
      callback.(item) && (is_nil(match) || apply(match, args))
    end)
    |> case do
      nil -> {:error, :not_found}
      index -> {:ok, index}
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp try_run_handler(handler, data, connection_state, stacktrace) do
    data
    |> run_handler(handler, connection_state)
    |> validate_response!(stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_handler(data, handler, connection_state) when is_function(handler, 2) do
    handler.(data, connection_state)
  end

  defp validate_response!(response, stacktrace) do
    case response do
      {:reply, data, state} ->
        {:reply, data, state}

      {:ok, state} ->
        {:ok, state}

      _other ->
        raise """
        Invalid callback response, got: #{inspect(response)}.

        Expected one of the following:

          - {:reply, data, state}, where data is iodata
          - {:ok, state}

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end

  defp update_connection_response({:reply, data, connection_state}, owner, state) do
    {{:reply, data}, update_connection_state(state, owner, connection_state)}
  end

  defp update_connection_response({:ok, connection_state}, owner, state) do
    {:ok, update_connection_state(state, owner, connection_state)}
  end

  defp update_connection_response(response, _owner, state) do
    {response, state}
  end

  defp update_connection_state(state, owner, connection_state) do
    case Enum.find_index(state.connections, &(&1.owner == owner)) do
      nil ->
        state

      index ->
        connections =
          List.update_at(state.connections, index, fn connection ->
            %{connection | state: connection_state}
          end)

        %{state | connections: connections}
    end
  end

  defp do_send(%{owner: owner} = connection, options, stacktrace, state) do
    case Process.alive?(owner) do
      true ->
        connection
        |> run_send_handler(Keyword.fetch!(options, :to), stacktrace)
        |> update_send_response(connection, state)

      false ->
        {{:error, :closed}, state}
    end
  end

  defp run_send_handler(connection, handler, stacktrace) when is_function(handler, 1) do
    connection.state
    |> handler.()
    |> validate_response!(stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp update_send_response({:reply, data, connection_state}, connection, state) do
    send(connection.owner, {:write, data})
    {:ok, update_connection_state(state, connection.owner, connection_state)}
  end

  defp update_send_response({:ok, connection_state}, connection, state) do
    {:ok, update_connection_state(state, connection.owner, connection_state)}
  end

  defp update_send_response({:error, {exception, stacktrace}}, connection, state) do
    send(connection.owner, {:write, Exception.format(:error, exception, stacktrace)})
    {{:error, {exception, stacktrace}}, state}
  end
end
