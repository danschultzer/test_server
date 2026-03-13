defmodule TestServer.SSH.Instance do
  @moduledoc false

  use GenServer

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(pid(), {:channel, TestServer.stacktrace()}) :: {:ok, reference()}
  def register(instance, {:channel, stacktrace}) do
    GenServer.call(instance, {:register, :channel, stacktrace})
  end

  @spec register(pid(), {:handle, {reference(), keyword(), TestServer.stacktrace()}}) ::
          {:ok, map()}
  def register(instance, {:handle, {channel_ref, options, stacktrace}}) do
    options[:to] && ensure_function!(options[:to])
    options[:match] && ensure_function!(options[:match])

    GenServer.call(instance, {:register, {:handle, {channel_ref, options, stacktrace}}})
  end

  defp ensure_function!(fun) when is_function(fun), do: :ok
  defp ensure_function!(fun), do: raise(BadFunctionError, term: fun)

  @spec dispatch(pid(), {:channel_up, pid()} | {:handle, tuple(), reference()}) ::
          {:ok, reference()}
          | {:ok, {:reply, term()}}
          | {:ok, {:reply, term(), keyword()}}
          | {:ok, :noreply}
          | {:ok, :ignore}
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, message) do
    GenServer.call(instance, {:dispatch, message})
  end

  @spec handlers(pid()) :: [map()]
  def handlers(instance) do
    GenServer.call(instance, :handlers)
  end

  @spec get_options(pid()) :: keyword()
  def get_options(instance) do
    GenServer.call(instance, :options)
  end

  @spec format_handlers([map()]) :: binary()
  def format_handlers(handlers) do
    handlers
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {handler, index} ->
      match_label = if handler.match, do: " match: #{inspect(handler.match)}", else: ""

      """
      ##{index + 1}:#{match_label} #{inspect(handler.to)}
          #{Enum.map_join(handler.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
      """
    end)
  end

  @spec report_error(pid(), {struct(), TestServer.stacktrace()}) :: :ok
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
           connections: %{},
           handlers: [],
           channel_states: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register, :channel, stacktrace}, _from, state) do
    channel = %{ref: make_ref(), claimed: false, stacktrace: stacktrace}

    {:reply, {:ok, channel.ref}, %{state | channels: state.channels ++ [channel]}}
  end

  def handle_call({:dispatch, {:channel_up, connection}}, _from, state) do
    case resolve_channel(connection, state) do
      {{:ok, channel_ref}, state} ->
        {:reply, {:ok, channel_ref}, state}

      {{:error, reason}, state} ->
        exception = RuntimeError.exception(channel_error_message(reason))
        {:reply, {:error, {exception, []}}, state}
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

  def handle_call({:dispatch, {:handle, inner, channel_ref}}, _from, state) do
    {res, state} = run_handlers(inner, channel_ref, state)

    {:reply, res, state}
  end

  def handle_call(option, _from, state) when option in [:handlers, :options] do
    {:reply, Map.fetch!(state, option), state}
  end

  defp resolve_channel(connection, state) do
    case Map.fetch(state.connections, connection) do
      {:ok, channel_ref} -> {{:ok, channel_ref}, state}
      :error -> claim_next_channel(connection, state)
    end
  end

  defp claim_next_channel(_connection, %{channels: []} = state) do
    {{:error, :no_channel_registered}, state}
  end

  defp claim_next_channel(connection, state) do
    case Enum.find_index(state.channels, &(!&1.claimed)) do
      nil ->
        {{:error, :no_available_channel}, state}

      index ->
        channel = Enum.at(state.channels, index)
        channels = List.update_at(state.channels, index, &%{&1 | claimed: true})
        connections = Map.put(state.connections, connection, channel.ref)

        {{:ok, channel.ref}, %{state | channels: channels, connections: connections}}
    end
  end

  defp run_handlers(inner, channel_ref, state) do
    channel_state = Map.get(state.channel_states, channel_ref)

    state.handlers
    |> Enum.find_index(fn
      %{channel_ref: ^channel_ref, suspended: true} -> false
      %{channel_ref: ^channel_ref, match: nil} -> true
      %{channel_ref: ^channel_ref, match: match} -> match.(inner, channel_state)
      _ -> false
    end)
    |> case do
      nil ->
        {{:error, :not_found}, state}

      index ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.handlers, index)

        {result, channel_states} =
          try_run_handler(
            handler,
            inner,
            channel_state,
            channel_ref,
            state.channel_states,
            stacktrace
          )

        handlers =
          List.update_at(state.handlers, index, fn h ->
            %{h | suspended: true, received: h.received ++ [inner]}
          end)

        {result, %{state | handlers: handlers, channel_states: channel_states}}
    end
  end

  defp try_run_handler(handler, inner, channel_state, channel_ref, channel_states, stacktrace) do
    {response, new_state} =
      inner
      |> handler.(channel_state)
      |> validate_response!(stacktrace)

    {{:ok, response}, Map.put(channel_states, channel_ref, new_state)}
  rescue
    error -> {{:error, {error, __STACKTRACE__}}, channel_states}
  end

  defp validate_response!({:reply, {data, opts}, state}, _stacktrace) when is_list(opts),
    do: {{:reply, data, opts}, state}

  defp validate_response!({:reply, data, state}, _stacktrace),
    do: {{:reply, data}, state}

  defp validate_response!({:ignore, state}, _stacktrace),
    do: {:ignore, state}

  defp validate_response!({:ok, state}, _stacktrace),
    do: {:noreply, state}

  defp validate_response!(response, stacktrace) do
    raise """
    Invalid callback response, got: #{inspect(response)}.

    Expected one of the following:

      - {:reply, data, state}
      - {:reply, {data, exit_status: code, stderr: message}, state}
      - {:ignore, state}
      - {:ok, state}

    #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
    """
  end

  defp default_handler({:exec, _channel_id, _want_reply, command}, state),
    do: {:reply, to_string(command), state}

  defp default_handler({:data, _channel_id, _type, data}, state),
    do: {:reply, data, state}

  defp default_handler(_inner, state),
    do: {:ok, state}

  defp channel_error_message(:no_channel_registered) do
    "#{TestServer.format_instance(TestServer.SSH, self())} received an SSH channel but no channels were registered"
  end

  defp channel_error_message(:no_available_channel) do
    "#{TestServer.format_instance(TestServer.SSH, self())} received an SSH channel but all registered channels are already in use"
  end
end
