defmodule TestServer.SSH.Instance do
  @moduledoc false

  use GenServer

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def register(instance, {type, options, stacktrace}) when type in [:exec, :shell] do
    options[:match] && ensure_function!(options[:match], 2)
    ensure_function!(Keyword.fetch!(options, :to), 2)
    GenServer.call(instance, {:register, {type, options, stacktrace}})
  end

  defp ensure_function!(fun, arity) when is_function(fun, arity), do: :ok
  defp ensure_function!(fun, _arity), do: raise(BadFunctionError, term: fun)

  def get_options(instance) do
    GenServer.call(instance, :options)
  end

  def handlers(instance, type) when type in [:exec, :shell] do
    GenServer.call(instance, {:handlers, type})
  end

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
    Process.flag(:trap_exit, true)

    host_key = :public_key.generate_key({:rsa, 2048, 65_537})
    port = Keyword.get(options, :port, 0)
    credentials = options[:credentials]
    instance = self()

    daemon_opts = build_daemon_opts(instance, host_key, credentials)

    case :ssh.daemon(port, daemon_opts) do
      {:ok, daemon_ref} ->
        {:ok, info} = :ssh.daemon_info(daemon_ref)
        actual_port = :proplists.get_value(:port, info)

        options =
          options
          |> Keyword.put(:port, actual_port)
          |> Keyword.put(:ip, {127, 0, 0, 1})
          |> Keyword.put(:protocol, :ssh)

        {:ok,
         %{
           options: options,
           host_key: host_key,
           daemon_ref: daemon_ref,
           handlers: %{exec: [], shell: []}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp build_daemon_opts(instance, host_key, credentials) do
    base = [
      system_dir: String.to_charlist(System.tmp_dir!()),
      key_cb: {TestServer.SSH.KeyAPI, [instance: instance, host_key: host_key]},
      ssh_cli: {TestServer.SSH.Channel, [instance: instance]},
      subsystems: [],
      auth_methods: ~c"password,publickey"
    ]

    if credentials do
      Keyword.put(base, :pwdfun, fn user, pass ->
        GenServer.call(instance, {:check_password, to_string(user), to_string(pass)})
      end)
    else
      base
      |> Keyword.put(:no_auth_needed, true)
      |> Keyword.delete(:auth_methods)
    end
  end

  @impl true
  def handle_call({:register, {type, options, stacktrace}}, _from, state)
      when type in [:exec, :shell] do
    handler = build_handler(options, stacktrace)
    updated_handlers = state.handlers[type] ++ [handler]
    {:reply, {:ok, handler}, put_in(state, [:handlers, type], updated_handlers)}
  end

  def handle_call({:dispatch, {type, input, chan_state}}, _from, state)
      when type in [:exec, :shell] do
    {result, updated_handlers} = dispatch(state.handlers[type], input, chan_state)
    {:reply, result, put_in(state, [:handlers, type], updated_handlers)}
  end

  def handle_call({:check_password, user, pass}, _from, state) do
    result =
      Enum.any?(state.options[:credentials] || [], fn
        {^user, ^pass} -> true
        _ -> false
      end)

    {:reply, result, state}
  end

  def handle_call({:is_auth_key, user, pub_key}, _from, state) do
    result =
      Enum.any?(state.options[:credentials] || [], fn
        {^user, :public_key, pem} ->
          case :public_key.pem_decode(pem) do
            [{_type, _der, :not_encrypted} = entry] ->
              :public_key.pem_entry_decode(entry) == pub_key

            _ ->
              false
          end

        _ ->
          false
      end)

    {:reply, result, state}
  end

  def handle_call(:options, _from, state) do
    {:reply, state.options, state}
  end

  def handle_call({:handlers, type}, _from, state) when type in [:exec, :shell] do
    {:reply, state.handlers[type], state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :ssh.stop_daemon(state.daemon_ref)
  end

  defp build_handler(options, stacktrace) do
    %{
      ref: make_ref(),
      match: options[:match],
      to: Keyword.fetch!(options, :to),
      stacktrace: stacktrace,
      suspended: false,
      received: []
    }
  end

  defp dispatch(handlers, input, chan_state) do
    handlers
    |> Enum.find_index(fn
      %{suspended: true} -> false
      %{match: nil} -> true
      %{match: match} -> try_match(match, input, chan_state)
    end)
    |> case do
      nil ->
        {{:error, :not_found}, handlers}

      index ->
        %{to: handler} = Enum.at(handlers, index)
        result = try_handler(handler, input, chan_state)

        updated_handlers =
          List.update_at(handlers, index, fn h ->
            %{h | suspended: true, received: h.received ++ [input]}
          end)

        {result, updated_handlers}
    end
  end

  defp try_match(match, input, chan_state) do
    match.(input, chan_state)
  rescue
    _ -> false
  end

  defp try_handler(handler, input, chan_state) do
    case handler.(input, chan_state) do
      {:reply, _, _} = reply ->
        {:ok, reply}

      {:ok, _} = ok ->
        {:ok, ok}

      other ->
        {:error, {RuntimeError.exception("Invalid handler response: #{inspect(other)}"), []}}
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end
end
