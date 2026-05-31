defmodule TestServer.SSH.Instance do
  @moduledoc false

  use GenServer

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(TestServer.instance(), {:channel, {keyword(), TestServer.stacktrace()}}) ::
          {:ok, %{ref: TestServer.SSH.channel_ref()}}
  def register(instance, {:channel, {options, stacktrace}}) do
    options[:listen] && ensure_listen!(options[:listen])

    GenServer.call(instance, {:register, {:channel, {options, stacktrace}}})
  end

  @spec register(
          TestServer.instance(),
          {:handle, {TestServer.SSH.channel_ref(), keyword(), TestServer.stacktrace()}}
        ) ::
          {:ok, map()}
  def register(instance, {:handle, {channel_ref, options, stacktrace}}) do
    options[:to] && ensure_function!(options[:to])
    options[:match] && ensure_function!(options[:match])

    GenServer.call(instance, {:register, {:handle, {channel_ref, options, stacktrace}}})
  end

  @listen_events ~w(exec data env pty shell eof)a

  defp ensure_listen!(listen) when is_list(listen) do
    case Enum.all?(listen, &(&1 in @listen_events)) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "expected list to only include #{inspect(@listen_events)}, got: #{inspect(listen)}"
    end
  end

  defp ensure_listen!(listen) do
    case listen do
      :all -> :ok
      _ -> raise ArgumentError, "expected :all, got: #{inspect(listen)}"
    end
  end

  defp ensure_function!(fun) when is_function(fun), do: :ok
  defp ensure_function!(fun), do: raise(BadFunctionError, term: fun)

  @spec dispatch(
          TestServer.instance(),
          {:channel_up, TestServer.SSH.channel_id(), TestServer.SSH.connection()}
        ) ::
          {:ok, {TestServer.SSH.channel_ref(), keyword(), TestServer.stacktrace()}}
          | {:error, :not_found}
  def dispatch(instance, {:channel_up, channel_id, connection}) do
    GenServer.call(instance, {:dispatch, {:channel_up, channel_id, connection}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:handle, TestServer.SSH.channel_id(), TestServer.SSH.connection(),
           TestServer.SSH.channel_msg(), TestServer.SSH.state()}
        ) ::
          {:raw, {:ok, TestServer.SSH.state()}}
          | {:raw, {:stop, TestServer.SSH.channel_id(), TestServer.SSH.state()}}
          | {:reply, {binary(), keyword()}, TestServer.SSH.state()}
          | {:ok, TestServer.SSH.state()}
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:handle, channel_ref, connection, message, channel_state}) do
    GenServer.call(
      instance,
      {:dispatch, {:handle, channel_ref, connection, {message, channel_state}}}
    )
  end

  @spec handlers(TestServer.instance()) :: [map()]
  def handlers(instance) do
    GenServer.call(instance, :handlers)
  end

  @spec channels(TestServer.instance()) :: [map()]
  def channels(instance) do
    GenServer.call(instance, :channels)
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

  @spec format_channels([map()]) :: binary()
  def format_channels(channels) do
    channels
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {channel, index} ->
      """
      ##{index + 1}: #{inspect(channel.ref)}
          #{Enum.map_join(channel.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
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
    alias TestServer.SSH.Server

    case Server.start(self(), options) do
      {:ok, options} ->
        {:ok,
         %{
           options: options,
           channels: [],
           handlers: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register, {:channel, {options, stacktrace}}}, _from, state) do
    channel = %{
      ref: make_ref(),
      options: options,
      stacktrace: stacktrace,
      channel_id: nil,
      connection_ref: nil
    }

    {:reply, {:ok, channel}, %{state | channels: state.channels ++ [channel]}}
  end

  def handle_call({:dispatch, {:channel_up, channel_id, connection_ref}}, _from, state) do
    case Enum.find_index(state.channels, &(is_nil(&1.channel_id) and is_nil(&1.connection_ref))) do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        updated_channel = %{
          Enum.at(state.channels, index)
          | channel_id: channel_id,
            connection_ref: connection_ref
        }

        channels = List.replace_at(state.channels, index, updated_channel)

        {:reply, {:ok, updated_channel}, %{state | channels: channels}}
    end
  end

  def handle_call({:register, {:handle, {channel_ref, options, stacktrace}}}, _from, state) do
    handler = %{
      ref: make_ref(),
      channel_ref: channel_ref,
      match: Keyword.get(options, :match),
      to: Keyword.get(options, :to, &default_handler/2),
      stacktrace: stacktrace,
      suspended: false,
      received: []
    }

    {:reply, {:ok, handler}, %{state | handlers: state.handlers ++ [handler]}}
  end

  def handle_call(
        {:dispatch, {:handle, channel_ref, connection, {message, channel_state}}},
        _from,
        state
      ) do
    {res, state} = run_handlers(message, channel_ref, connection, channel_state, state)

    {:reply, res, state}
  end

  def handle_call(option, _from, state) when option in [:handlers, :channels, :options] do
    {:reply, Map.fetch!(state, option), state}
  end

  defp default_handler({:exec, _channel_id, _want_reply, command}, state),
    do: {:reply, to_string(command), state}

  defp default_handler({:data, _channel_id, _type, data}, state),
    do: {:reply, data, state}

  defp default_handler(_message, state),
    do: {:ok, state}

  defp run_handlers(message, channel_ref, connection, channel_state, state) do
    state.handlers
    |> fetch_match_index([message, channel_state], fn
      %{channel_ref: ^channel_ref, suspended: true} -> false
      %{channel_ref: ^channel_ref, suspended: false} -> true
      %{channel_ref: _other, suspended: _any} -> false
    end)
    |> case do
      {:error, :not_found} ->
        {{:error, :not_found}, state}

      {:error, {error, stacktrace}} ->
        {{:error, {error, stacktrace}}, state}

      {:ok, index} ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.handlers, index)

        result = try_run_handler(handler, message, connection, channel_state, stacktrace)

        handlers =
          List.update_at(state.handlers, index, fn h ->
            %{h | suspended: true, received: h.received ++ [message]}
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

  defp try_run_handler(handler, message, connection, channel_state, stacktrace) do
    message
    |> run_handler(handler, connection, channel_state)
    |> validate_response!(handler, stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_handler(message, handler, connection, channel_state) when is_function(handler, 3) do
    handler.(message, connection, channel_state)
  end

  defp run_handler(message, handler, _connection, channel_state) when is_function(handler, 2) do
    handler.(message, channel_state)
  end

  defp validate_response!(response, handler, stacktrace) when is_function(handler, 3) do
    case response do
      {:ok, state} ->
        {:raw, {:ok, state}}

      {:stop, channel_id, state} ->
        {:raw, {:stop, channel_id, state}}

      _other ->
        raise """
        Invalid callback response, got: #{inspect(response)}.

        Expected one of the following:

          - {:ok, state}
          - {:stop, channel_id, state}

          #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end

  defp validate_response!(response, handler, stacktrace) when is_function(handler, 2) do
    case response do
      {:reply, {data, options}, state} ->
        validate_options!({:reply, {data, options}, state}, stacktrace)

        {:reply, {data, options}, state}

      {:reply, data, state} when is_binary(data) ->
        {:reply, {data, []}, state}

      {:ok, state} ->
        {:ok, state}

      _other ->
        raise """
        Invalid callback response, got: #{inspect(response)}.

        Expected one of the following:

          - {:reply, data, state}
          - {:reply, {data, options}, state}
          - {:ok, state}

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end

  defp validate_options!({:reply, {_data, options}, _state}, stacktrace) do
    valid_options = ~w(exit_status data_type_code)a

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
end
