defmodule TestServer.SSH.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.SSH.Server

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(TestServer.instance(), {:channel, keyword(), TestServer.stacktrace()}) ::
          {:ok, %{ref: TestServer.SSH.channel_ref()}}
  def register(instance, {:channel, options, stacktrace}) do
    Keyword.has_key?(options, :messages) && validate_messages!(options[:messages])

    GenServer.call(instance, {:register, {:channel, options, stacktrace}})
  end

  @spec register(
          TestServer.instance(),
          {:handle, TestServer.SSH.channel_ref(), keyword(), TestServer.stacktrace()}
        ) ::
          {:ok, map()}
  def register(instance, {:handle, channel_ref, options, stacktrace}) do
    Keyword.has_key?(options, :match) && validate_function_option!(options, :match)
    Keyword.has_key?(options, :to) && validate_function_option!(options, :to)

    GenServer.call(instance, {:register, {:handle, channel_ref, options, stacktrace}})
  end

  @message_events ~w(exec data env pty shell eof)a

  defp validate_messages!(messages) when is_list(messages) do
    case Enum.all?(messages, &(&1 in @message_events)) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "expected :messages to contain only #{inspect(@message_events)}, got: #{inspect(messages)}"
    end
  end

  defp validate_messages!(messages) do
    case messages do
      :all ->
        :ok

      _ ->
        raise ArgumentError, "expected :messages to be :all or a list, got: #{inspect(messages)}"
    end
  end

  defp validate_function_option!(options, option) do
    value = Keyword.get(options, option)

    case is_function(value) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "expected #{inspect(option)} to be a function, got: #{inspect(value)}"
    end
  end

  @spec dispatch(
          TestServer.instance(),
          {:channel_up, :ssh.channel_id(), :ssh.connection_ref()}
        ) ::
          {:ok, {TestServer.SSH.channel_ref(), keyword()}}
          | {:error, :not_found}
  def dispatch(instance, {:channel_up, channel_id, connection}) do
    GenServer.call(instance, {:dispatch, {:channel_up, channel_id, connection}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:handle, TestServer.SSH.channel_ref(), :ssh.connection_ref(),
           :ssh_connection.channel_msg(), TestServer.SSH.state()}
        ) ::
          {:raw, {:ok, TestServer.SSH.state()}}
          | {:raw, {:stop, :ssh.channel_id(), TestServer.SSH.state()}}
          | {:reply, {iodata(), TestServer.SSH.reply_options()}, TestServer.SSH.state()}
          | {:ok, TestServer.SSH.response_options(), TestServer.SSH.state()}
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:handle, channel_ref, connection, message, channel_state}) do
    GenServer.call(
      instance,
      {:dispatch, {:handle, channel_ref, connection, message, channel_state}}
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

  @spec options(TestServer.instance()) :: keyword()
  def options(instance) do
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

  @impl true
  def init(options) do
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
  def handle_call({:register, {:channel, options, stacktrace}}, _from, state) do
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
        channel = %{
          Enum.at(state.channels, index)
          | channel_id: channel_id,
            connection_ref: connection_ref
        }

        channels = List.replace_at(state.channels, index, channel)

        {:reply, {:ok, {channel.ref, channel.options}}, %{state | channels: channels}}
    end
  end

  def handle_call({:register, {:handle, channel_ref, options, stacktrace}}, _from, state) do
    handler = %{
      channel_ref: channel_ref,
      match: Keyword.get(options, :match),
      to: Keyword.fetch!(options, :to),
      stacktrace: stacktrace,
      suspended: false
    }

    {:reply, {:ok, handler}, %{state | handlers: state.handlers ++ [handler]}}
  end

  def handle_call(
        {:dispatch, {:handle, channel_ref, connection, message, channel_state}},
        _from,
        state
      ) do
    {result, state} = run_handlers(message, channel_ref, connection, channel_state, state)

    {:reply, result, state}
  end

  def handle_call(option, _from, state) when option in [:handlers, :channels, :options] do
    {:reply, Map.fetch!(state, option), state}
  end

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
        invalid callback response, got: #{inspect(response)}

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
        validate_response_options!(options, ~w(exit_status data_type_code close)a, stacktrace)

        {:reply, {data, options}, state}

      {:reply, data, state} ->
        {:reply, {data, []}, state}

      {:ok, state} ->
        {:ok, [], state}

      {:ok, options, state} ->
        validate_response_options!(options, ~w(exit_status close)a, stacktrace)

        {:ok, options, state}

      _other ->
        raise """
        invalid callback response, got: #{inspect(response)}

        Expected one of the following:

          - {:reply, data, state}
          - {:reply, {data, options}, state}
          - {:ok, state}
          - {:ok, options, state}

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end

  defp validate_response_options!(options, valid_options, stacktrace) do
    with true <- validate_options(options, valid_options),
         true <- validate_close_option(options),
         true <- validate_exit_status_option(options),
         true <- validate_data_type_code_option(options) do
      :ok
    else
      false ->
        raise """
        invalid options in callback response, got: #{inspect(options)}

        Valid options are: #{inspect(valid_options)}

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end

  defp validate_options(options, valid_options) do
    case Keyword.validate(options, valid_options) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp validate_close_option(options) do
    case Keyword.has_key?(options, :close) do
      true -> is_boolean(Keyword.get(options, :close))
      false -> true
    end
  end

  @max_uint32 0xFFFF_FFFF

  defp validate_exit_status_option(options) do
    case Keyword.has_key?(options, :exit_status) do
      true -> Keyword.get(options, :exit_status) in 0..@max_uint32
      false -> true
    end
  end

  defp validate_data_type_code_option(options) do
    case Keyword.has_key?(options, :data_type_code) do
      true -> Keyword.get(options, :data_type_code) in 0..@max_uint32
      false -> true
    end
  end
end
