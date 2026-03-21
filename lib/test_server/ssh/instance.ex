defmodule TestServer.SSH.Instance do
  @moduledoc false

  use GenServer

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register_channel(pid()) :: {:ok, reference()}
  def register_channel(instance) do
    GenServer.call(instance, :register_channel)
  end

  @spec claim_channel(pid(), pid()) :: {:ok, reference()} | {:error, :no_channel}
  def claim_channel(instance, connection) do
    GenServer.call(instance, {:claim_channel, connection})
  end

  @spec register(pid(), {reference(), keyword(), TestServer.stacktrace()}) :: {:ok, map()}
  def register(instance, {channel_ref, options, stacktrace}) do
    to = Keyword.get(options, :to)
    to && ensure_function!(to, 2)
    match = Keyword.get(options, :match)
    match && ensure_function!(match, 2)

    GenServer.call(instance, {:register, {channel_ref, options, stacktrace}})
  end

  defp ensure_function!(fun, arity) when is_function(fun, arity), do: :ok

  defp ensure_function!(fun, arity) do
    raise ArgumentError,
          "expected a function with arity #{arity}, got: #{inspect(fun)}"
  end

  @spec dispatch(pid(), {atom(), binary()}, reference()) ::
          {:ok, {:reply, term()}}
          | {:ok, {:reply, term(), keyword()}}
          | {:ok, :ok}
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {type, input}, channel_ref) do
    GenServer.call(instance, {:dispatch, {type, input}, channel_ref})
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

  # Server callbacks

  @impl true
  def init(options) do
    host_key =
      Keyword.get_lazy(options, :host_key, fn ->
        :public_key.generate_key({:rsa, 2048, 65_537})
      end)

    port = Keyword.get(options, :port, 0)
    ip = Keyword.get(options, :ip, {127, 0, 0, 1})
    daemon_options = build_daemon_options(options, host_key)

    case :ssh.daemon(ip, port, daemon_options) do
      {:ok, daemon_ref} ->
        resolved_port = resolve_port(daemon_ref)

        options =
          options
          |> Keyword.put(:port, resolved_port)
          |> Keyword.put(:ip, ip)

        {:ok,
         %{
           options: options,
           host_key: host_key,
           daemon_ref: daemon_ref,
           channels: [],
           connections: %{},
           handlers: [],
           channel_states: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp build_daemon_options(options, host_key) do
    instance = self()
    tmp_dir = String.to_charlist(System.tmp_dir!())

    [
      key_cb: {TestServer.SSH.KeyAPI, host_key: host_key, instance: instance},
      ssh_cli: {TestServer.SSH.Channel, [instance: instance]},
      system_dir: tmp_dir,
      user_dir: tmp_dir,
      parallel_login: true
    ] ++ auth_options(Keyword.get(options, :credentials, []), instance)
  end

  defp auth_options([], _instance), do: [no_auth_needed: true]

  defp auth_options(credentials, _instance) do
    user_passwords =
      for {user, password} when is_binary(password) <- credentials do
        {String.to_charlist(user), String.to_charlist(password)}
      end

    [user_passwords: user_passwords]
  end

  defp resolve_port(daemon_ref) do
    {:ok, info} = :ssh.daemon_info(daemon_ref)
    {_, port} = List.keyfind(info, :port, 0)
    port
  end

  @impl true
  def handle_call(:register_channel, _from, state) do
    channel = %{ref: make_ref(), claimed: false}

    {:reply, {:ok, channel.ref}, %{state | channels: state.channels ++ [channel]}}
  end

  def handle_call({:claim_channel, connection}, _from, state) do
    case Map.fetch(state.connections, connection) do
      {:ok, channel_ref} ->
        {:reply, {:ok, channel_ref}, state}

      :error ->
        case Enum.find_index(state.channels, &(!&1.claimed)) do
          nil ->
            {:reply, {:error, :no_channel}, state}

          index ->
            channel = Enum.at(state.channels, index)
            channels = List.update_at(state.channels, index, &%{&1 | claimed: true})
            connections = Map.put(state.connections, connection, channel.ref)

            {:reply, {:ok, channel.ref}, %{state | channels: channels, connections: connections}}
        end
    end
  end

  def handle_call({:register, {channel_ref, options, stacktrace}}, _from, state) do
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

  def handle_call({:dispatch, {type, input}, channel_ref}, _from, state) do
    {res, state} = run_handlers({type, input}, channel_ref, state)

    {:reply, res, state}
  end

  def handle_call(:handlers, _from, state) do
    {:reply, state.handlers, state}
  end

  def handle_call(:options, _from, state) do
    {:reply, state.options, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state[:daemon_ref] do
      :ssh.stop_daemon(state.daemon_ref)
    end

    :ok
  end

  # Handler dispatch

  defp run_handlers({type, input}, channel_ref, state) do
    channel_state = Map.get(state.channel_states, channel_ref)

    state.handlers
    |> Enum.map(&{&1.channel_ref == channel_ref, &1})
    |> Enum.find_index(fn
      {false, _} -> false
      {true, %{suspended: true}} -> false
      {true, %{match: nil}} -> true
      {true, %{match: match}} -> try_match(match, {type, input}, channel_state)
    end)
    |> case do
      nil ->
        {{:error, :not_found}, state}

      index ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.handlers, index)

        result = try_dispatch(handler, {type, input}, channel_state, stacktrace)

        handlers =
          List.update_at(state.handlers, index, fn h ->
            %{h | suspended: result_ok?(result), received: h.received ++ [input]}
          end)

        channel_states = update_channel_state(state.channel_states, channel_ref, result)

        {to_channel_result(result), %{state | handlers: handlers, channel_states: channel_states}}
    end
  end

  defp to_channel_result({:ok, {response, _new_state}}), do: {:ok, response}
  defp to_channel_result({:error, _} = error), do: error

  defp try_match(match, tagged_input, channel_state) do
    match.(tagged_input, channel_state)
  rescue
    FunctionClauseError -> false
  end

  defp try_dispatch(handler, {type, input}, channel_state, stacktrace) do
    response =
      {type, input}
      |> handler.(channel_state)
      |> validate_response!(stacktrace)

    {:ok, response}
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp result_ok?({:ok, _}), do: true
  defp result_ok?(_), do: false

  defp update_channel_state(channel_states, _channel_ref, {:error, _}), do: channel_states

  defp update_channel_state(channel_states, channel_ref, {:ok, {_response, new_state}}) do
    Map.put(channel_states, channel_ref, new_state)
  end

  defp validate_response!({:reply, {data, opts}, state}, _stacktrace) when is_list(opts),
    do: {{:reply, data, opts}, state}

  defp validate_response!({:reply, data, state}, _stacktrace),
    do: {{:reply, data}, state}

  defp validate_response!({:ok, state}, _stacktrace),
    do: {:ok, state}

  defp validate_response!(response, stacktrace) do
    raise """
    Invalid callback response, got: #{inspect(response)}.

    Expected one of the following:

      - {:reply, data, state}
      - {:reply, {data, exit: code, stderr: message}, state}
      - {:ok, state}

    #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
    """
  end

  defp default_handler({_type, input}, state), do: {:reply, input, state}
end
