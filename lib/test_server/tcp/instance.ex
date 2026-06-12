defmodule TestServer.TCP.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.TCP.Server

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(TestServer.instance(), {:connect, {keyword(), TestServer.stacktrace()}}) ::
          {:ok, %{ref: TestServer.TCP.connection_ref()}}
  def register(instance, {:connect, {options, stacktrace}}) do
    GenServer.call(instance, {:register, {:connect, {options, stacktrace}}})
  end

  @spec register(
          TestServer.instance(),
          {:handle, {TestServer.TCP.connection_ref() | nil, keyword(), TestServer.stacktrace()}}
        ) :: {:ok, map()}
  def register(instance, {:handle, {connection_ref, options, stacktrace}}) do
    options[:to] && ensure_function!(options[:to])
    options[:match] && ensure_function!(options[:match])

    GenServer.call(instance, {:register, {:handle, {connection_ref, options, stacktrace}}})
  end

  defp ensure_function!(fun) when is_function(fun), do: :ok
  defp ensure_function!(fun), do: raise(BadFunctionError, term: fun)

  @spec dispatch(TestServer.instance(), {:handle, pid(), binary()}) ::
          {:reply, TestServer.TCP.data()}
          | :ok
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:handle, connection_pid, data}) do
    GenServer.call(instance, {:dispatch, {:handle, {connection_pid, data}}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:send, {TestServer.TCP.connection_ref(), keyword(), TestServer.stacktrace()}}
        ) ::
          {:send, port(), iodata()}
          | :ok
          | {:error, :not_found}
          | {:error, :not_connected}
          | {:error, {term(), TestServer.stacktrace()}, port()}
  def dispatch(instance, {:send, {connection_ref, options, stacktrace}}) do
    options[:to] && ensure_function!(options[:to])

    GenServer.call(instance, {:dispatch, {:send, {connection_ref, options, stacktrace}}})
  end

  @spec register_connection(TestServer.instance(), pid(), port()) :: :ok
  def register_connection(instance, connection_pid, socket) do
    GenServer.call(instance, {:register, {:connection, {connection_pid, socket}}})
  end

  @spec unregister_connection(TestServer.instance(), pid()) :: :ok
  def unregister_connection(instance, connection_pid) do
    GenServer.cast(instance, {:unregister, {:connection, connection_pid}})
  end

  @spec handlers(TestServer.instance()) :: [map()]
  def handlers(instance) do
    GenServer.call(instance, :handlers)
  end

  @spec connections(TestServer.instance()) :: [map()]
  def connections(instance) do
    GenServer.call(instance, :connections)
  end

  @spec get_options(TestServer.instance()) :: keyword()
  def get_options(instance) do
    GenServer.call(instance, :options)
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

  @spec report_error(TestServer.instance(), {struct(), TestServer.stacktrace()}) :: :ok
  def report_error(instance, {exception, stacktrace}) do
    options = get_options(instance)
    caller = Keyword.fetch!(options, :caller)

    unless Keyword.get(options, :suppress_warning, false),
      do: IO.warn(Exception.format(:error, exception, stacktrace))

    ExUnit.OnExitHandler.add(caller, make_ref(), fn ->
      reraise exception, stacktrace
    end)

    :ok
  end

  @impl true
  def init(options) do
    {:ok, options} = Server.start(self(), options)

    {:ok, %{options: options, handlers: [], connections: []}}
  end

  @impl true
  def handle_call({:register, {:connect, {_options, stacktrace}}}, _from, state) do
    connection = %{
      ref: make_ref(),
      stacktrace: stacktrace,
      pid: nil,
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

  def handle_call({:register, {:connection, {connection_pid, socket}}}, _from, state) do
    {_connection, connections} = bind_connection(state.connections, connection_pid, socket)

    {:reply, :ok, %{state | connections: connections}}
  end

  def handle_call({:dispatch, {:handle, {connection_pid, data}}}, _from, state) do
    case find_connection_index_by_pid(state.connections, connection_pid) do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        connection = Enum.at(state.connections, index)
        {res, state} = run_handlers(data, connection, state)
        {res, state} = update_connection_response(res, connection_pid, state)

        {:reply, res, state}
    end
  end

  def handle_call(
        {:dispatch, {:send, {connection_ref, options, stacktrace}}},
        _from,
        state
      ) do
    to = Keyword.fetch!(options, :to)

    case find_connection_index_by_ref(state.connections, connection_ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        connection = Enum.at(state.connections, index)

        case connection.socket do
          nil ->
            {:reply, {:error, :not_connected}, state}

          _socket ->
            {result, state} =
              connection
              |> run_send_handler(to, stacktrace)
              |> update_send_response(connection, state)

            {:reply, result, state}
        end
    end
  end

  def handle_call(option, _from, state) when option in [:connections, :handlers, :options] do
    {:reply, Map.fetch!(state, option), state}
  end

  @impl true
  def handle_cast({:unregister, {:connection, connection_pid}}, state) do
    connections = Enum.reject(state.connections, &(&1.pid == connection_pid))

    {:noreply, %{state | connections: connections}}
  end

  defp bind_connection(connections, connection_pid, socket) do
    case Enum.find_index(connections, &(not is_nil(&1.ref) and is_nil(&1.pid))) do
      nil ->
        connection = %{
          ref: nil,
          stacktrace: [],
          pid: connection_pid,
          socket: socket,
          state: %{}
        }

        {connection, connections ++ [connection]}

      index ->
        connection = %{
          Enum.at(connections, index)
          | pid: connection_pid,
            socket: socket
        }

        {connection, List.replace_at(connections, index, connection)}
    end
  end

  defp run_handlers(data, connection, state) do
    state.handlers
    |> fetch_match_index([data, connection.state], fn
      %{suspended: true} -> false
      %{connection_ref: nil} -> true
      %{connection_ref: ref} -> ref == connection.ref
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
    |> validate_response!(handler, stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_handler(data, handler, connection_state) when is_function(handler, 2) do
    handler.(data, connection_state)
  end

  defp run_send_handler(connection, handler, stacktrace) when is_function(handler, 1) do
    connection.state
    |> handler.()
    |> validate_response!(handler, stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp validate_response!(response, handler, stacktrace) when is_function(handler, 2) do
    validate_handler_response!(response, stacktrace)
  end

  defp validate_response!(response, handler, stacktrace) when is_function(handler, 1) do
    validate_handler_response!(response, stacktrace)
  end

  defp validate_handler_response!(response, stacktrace) do
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

  defp find_connection_index_by_pid(connections, connection_pid) do
    Enum.find_index(connections, &(&1.pid == connection_pid))
  end

  defp find_connection_index_by_ref(connections, connection_ref) do
    Enum.find_index(connections, &(&1.ref == connection_ref))
  end

  defp update_connection_response({:reply, data, connection_state}, connection_pid, state) do
    {{:reply, data}, update_connection_state(state, connection_pid, connection_state)}
  end

  defp update_connection_response({:ok, connection_state}, connection_pid, state) do
    {:ok, update_connection_state(state, connection_pid, connection_state)}
  end

  defp update_connection_response(response, _connection_pid, state) do
    {response, state}
  end

  defp update_send_response({:reply, data, connection_state}, connection, state) do
    {{:send, connection.socket, data},
     update_connection_state(state, connection.pid, connection_state)}
  end

  defp update_send_response({:ok, connection_state}, connection, state) do
    {:ok, update_connection_state(state, connection.pid, connection_state)}
  end

  defp update_send_response({:error, {exception, stacktrace}}, connection, state) do
    {{:error, {exception, stacktrace}, connection.socket}, state}
  end

  defp update_connection_state(state, connection_pid, connection_state) do
    case find_connection_index_by_pid(state.connections, connection_pid) do
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
end
