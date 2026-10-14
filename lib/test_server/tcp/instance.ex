defmodule TestServer.TCP.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.TCP.Server

  @send_timeout 1_000

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @spec register(TestServer.instance(), {:connection, TestServer.stacktrace()}) ::
          {:ok, %{ref: TestServer.TCP.connection_ref()}}
  def register(instance, {:connection, stacktrace}) do
    GenServer.call(instance, {:register, {:connection, stacktrace}})
  end

  @spec register(
          TestServer.instance(),
          {:handle, TestServer.TCP.connection_ref(), keyword(), TestServer.stacktrace()}
        ) :: {:ok, map()}
  def register(instance, {:handle, connection_ref, options, stacktrace}) do
    Keyword.has_key?(options, :to) && ensure_function!(options[:to])
    Keyword.has_key?(options, :match) && ensure_function!(options[:match])

    GenServer.call(instance, {:register, {:handle, connection_ref, options, stacktrace}})
  end

  @spec register(
          TestServer.instance(),
          {:send, TestServer.TCP.connection_ref(), keyword()}
        ) ::
          {:ok, pid()}
          | {:error, :einval}
          | {:error, :enotconn}
          | {:error, :closed}
  def register(instance, {:send, connection_ref, options}) do
    timeout = Keyword.get(options, :timeout, @send_timeout)

    Keyword.has_key?(options, :to) && ensure_function!(options[:to])
    Keyword.has_key?(options, :timeout) && ensure_integer!(timeout)

    GenServer.call(
      instance,
      {:register, {:send, connection_ref, timeout}},
      timeout + 1_000
    )
  end

  defp ensure_function!(fun) when is_function(fun), do: :ok
  defp ensure_function!(fun), do: raise(BadFunctionError, term: fun)

  defp ensure_integer!(value) when is_integer(value) and value > 0, do: :ok

  defp ensure_integer!(value),
    do: raise(ArgumentError, "expected positive integer, got: #{inspect(value)}")

  @spec dispatch(
          TestServer.instance(),
          {:connection, pid(), {:tcp, :gen_tcp.socket()} | {:tls, :ssl.socket()}}
        ) ::
          {:ok, map(), TestServer.TCP.state()} | {:error, :not_found}
  def dispatch(instance, {:connection, owner, socket}) do
    GenServer.call(instance, {:dispatch, {:connection, owner, socket}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:handle, pid(), TestServer.TCP.data(), TestServer.TCP.state()}
        ) ::
          {:reply, {iodata(), keyword()}, TestServer.TCP.state()}
          | {:ok, TestServer.TCP.state()}
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:handle, owner, data, connection_state}) do
    GenServer.call(instance, {:dispatch, {:handle, owner, data, connection_state}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:send, keyword(), TestServer.TCP.state(), TestServer.stacktrace()}
        ) ::
          {:reply, iodata(), TestServer.TCP.state()}
          | {:ok, TestServer.TCP.state()}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:send, options, connection_state, stacktrace}) do
    Keyword.has_key?(options, :to) && ensure_function!(options[:to])

    GenServer.call(instance, {:dispatch, {:send, options, connection_state, stacktrace}})
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
        {:ok, %{options: options, handlers: [], connections: []}}

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
      subscribers: []
    }

    {:reply, {:ok, connection}, %{state | connections: state.connections ++ [connection]}}
  end

  def handle_call({:register, {:handle, connection_ref, options, stacktrace}}, _from, state) do
    handler = %{
      connection_ref: connection_ref,
      match: Keyword.get(options, :match),
      to: Keyword.fetch!(options, :to),
      stacktrace: stacktrace,
      suspended: false
    }

    {:reply, {:ok, handler}, %{state | handlers: state.handlers ++ [handler]}}
  end

  def handle_call({:register, {:send, connection_ref, timeout}}, from, state) do
    {index, connection} = find_index_value(state.connections, &(&1.ref == connection_ref))
    alive? = connection && connection.owner && Process.alive?(connection.owner)

    case {connection, alive?} do
      {nil, _} ->
        {:reply, {:error, :einval}, state}

      {%{owner: nil} = connection, _} ->
        timer =
          Process.send_after(
            self(),
            {:timeout, from, {:send, index}},
            timeout
          )

        connection = %{connection | subscribers: connection.subscribers ++ [{from, timer}]}
        connections = put_index_value(state.connections, index, connection)
        state = %{state | connections: connections}

        {:noreply, state}

      {%{owner: _owner}, false} ->
        {:reply, {:error, :closed}, state}

      {%{owner: owner}, true} ->
        {:reply, {:ok, owner}, state}
    end
  end

  def handle_call({:dispatch, {:connection, owner, socket}}, _from, state) do
    connection =
      Enum.find_index(state.connections, &(&1.owner == owner)) ||
        Enum.find_index(state.connections, &is_nil(&1.owner))

    case connection do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        connection = %{Enum.at(state.connections, index) | owner: owner, socket: socket}
        connection = notify_connection_subscribers(connection, owner)
        connections = List.replace_at(state.connections, index, connection)
        state = %{state | connections: connections}

        {:reply, {:ok, connection, %{}}, state}
    end
  end

  def handle_call({:dispatch, {:handle, owner, data, connection_state}}, _from, state) do
    case Enum.find(state.connections, &(&1.owner == owner)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      connection ->
        {result, state} = run_handlers(data, connection, connection_state, state)

        {:reply, result, state}
    end
  end

  def handle_call(
        {:dispatch, {:send, options, connection_state, stacktrace}},
        _from,
        state
      ) do
    result =
      options
      |> Keyword.fetch!(:to)
      |> try_run_send_handler(connection_state, stacktrace)

    {:reply, result, state}
  end

  def handle_call(option, _from, state) when option in [:connections, :handlers, :options] do
    {:reply, Map.fetch!(state, option), state}
  end

  @impl true
  def handle_info({:timeout, from, {:send, connection_index}}, state) do
    case Enum.at(state.connections, connection_index) do
      %{subscribers: []} ->
        {:noreply, state}

      %{subscribers: subscribers} = connection ->
        subscribers =
          Enum.filter(subscribers, fn {subscriber_from, _timer} ->
            subscriber_from != from
          end)

        connections =
          put_index_value(state.connections, connection_index, %{
            connection
            | subscribers: subscribers
          })

        GenServer.reply(from, {:error, :enotconn})

        {:noreply, %{state | connections: connections}}
    end
  end

  defp notify_connection_subscribers(connection, owner) do
    Enum.each(connection.subscribers, fn {from, timer} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:ok, owner})
    end)

    %{connection | subscribers: []}
  end

  defp find_index_value(list, fun) do
    Enum.reduce_while(list, {0, nil}, fn item, {index, nil} ->
      case fun.(item) do
        true -> {:halt, {index, item}}
        false -> {:cont, {index + 1, nil}}
      end
    end)
  end

  defp put_index_value(list, index, value) do
    List.update_at(list, index, fn _ -> value end)
  end

  defp run_handlers(data, %{ref: connection_ref}, connection_state, state) do
    state.handlers
    |> fetch_match_index([data, connection_state], fn
      %{connection_ref: ^connection_ref, suspended: true} -> false
      %{connection_ref: ^connection_ref, suspended: false} -> true
      %{connection_ref: _other, suspended: _any} -> false
    end)
    |> case do
      {:error, :not_found} ->
        {{:error, :not_found}, state}

      {:error, {error, stacktrace}} ->
        {{:error, {error, stacktrace}}, state}

      {:ok, index} ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.handlers, index)

        result = try_run_handler(handler, data, connection_state, stacktrace)

        handlers =
          List.update_at(state.handlers, index, fn handler ->
            %{handler | suspended: true}
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
    |> validate_handler_response!(stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_handler(data, handler, connection_state) do
    handler.(data, connection_state)
  end

  defp validate_handler_response!(response, stacktrace) do
    case response do
      {:reply, {data, options}, state} ->
        validate_handler_options!(options, stacktrace)

        {:reply, {data, options}, state}

      {:reply, data, state} ->
        {:reply, {data, []}, state}

      {:ok, state} ->
        {:ok, state}

      _other ->
        raise """
        Invalid callback response, got: #{inspect(response)}.

        Expected one of the following:

          - {:reply, data, state}, where data is iodata
          - {:reply, {data, options}, state}, where data is iodata
          - {:ok, state}

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end

  defp validate_handler_options!(options, stacktrace) do
    valid_options = ~w(upgrade)a

    case Keyword.validate(options, valid_options) do
      {:ok, _options} ->
        :ok

      {:error, _keys} ->
        raise """
        Invalid options in callback response, got: #{inspect(options)}.

        Valid options are: #{inspect(valid_options)}.

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end

  defp try_run_send_handler(handler, connection_state, stacktrace) do
    handler
    |> run_send_handler(connection_state)
    |> validate_send_response!(stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_send_handler(handler, connection_state) do
    handler.(connection_state)
  end

  defp validate_send_response!(response, stacktrace) do
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
end
