defmodule TestServer.SMTP.Instance do
  @moduledoc false

  use GenServer

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def register(instance, {options, stacktrace}) do
    options[:match] && ensure_function!(options[:match], 2)
    ensure_function!(Keyword.fetch!(options, :to), 2)
    GenServer.call(instance, {:register, {options, stacktrace}})
  end

  defp ensure_function!(fun, arity) when is_function(fun, arity), do: :ok
  defp ensure_function!(fun, _arity), do: raise(BadFunctionError, term: fun)

  def get_options(instance) do
    GenServer.call(instance, :options)
  end

  def handlers(instance) do
    GenServer.call(instance, :handlers)
  end

  def format_instance(instance) do
    "#{inspect(__MODULE__)} #{inspect(instance)}"
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

    port = Keyword.get(options, :port, 0)
    tls = Keyword.get(options, :tls, :none)
    credentials = options[:credentials]
    hostname = Keyword.get(options, :hostname, "localhost")
    instance = self()

    {x509_suite, tls_options} = maybe_generate_x509(tls)

    listener_ref = make_ref()

    callback_opts = [
      instance: instance,
      tls: tls,
      credentials: credentials
    ]

    session_opts =
      [callbackoptions: callback_opts] ++
        if(tls_options != [], do: [tls_options: tls_options], else: [])

    server_options = [
      port: port,
      domain: hostname,
      sessionoptions: session_opts
    ]

    case :gen_smtp_server.start(listener_ref, TestServer.SMTP.Session, server_options) do
      {:ok, _} ->
        actual_port = :ranch.get_port(listener_ref)

        options =
          options
          |> Keyword.put(:port, actual_port)
          |> Keyword.put(:protocol, :smtp)

        {:ok,
         %{
           options: options,
           listener_ref: listener_ref,
           x509_suite: x509_suite,
           handlers: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp maybe_generate_x509(:starttls) do
    suite = X509.Test.Suite.new()
    key_der = X509.PrivateKey.to_der(suite.server_key)
    cert_der = X509.Certificate.to_der(suite.valid)

    tls_opts = [
      key: {:RSAPrivateKey, key_der},
      cert: cert_der,
      cacerts: suite.chain ++ suite.cacerts
    ]

    {suite, tls_opts}
  end

  defp maybe_generate_x509(_), do: {nil, []}

  @impl true
  def handle_call({:register, {options, stacktrace}}, _from, state) do
    handler = build_handler(options, stacktrace)
    {:reply, {:ok, handler}, %{state | handlers: state.handlers ++ [handler]}}
  end

  def handle_call({:dispatch, email}, _from, state) do
    {result, state} = dispatch(email, state)
    {:reply, result, state}
  end

  def handle_call({:check_credentials, user, pass}, _from, state) do
    result =
      Enum.any?(state.options[:credentials] || [], fn
        {^user, ^pass} -> true
        _ -> false
      end)

    {:reply, result, state}
  end

  def handle_call(:handlers, _from, state) do
    {:reply, state.handlers, state}
  end

  def handle_call(:options, _from, state) do
    {:reply, state.options, state}
  end

  def handle_call(:x509_suite, _from, state) do
    {:reply, state.x509_suite, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_smtp_server.stop(state.listener_ref)
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

  defp dispatch(email, state) do
    state.handlers
    |> Enum.find_index(fn
      %{suspended: true} -> false
      %{match: nil} -> true
      %{match: match} -> try_match(match, email, %{})
    end)
    |> case do
      nil ->
        {{:error, :not_found}, state}

      index ->
        %{to: handler} = Enum.at(state.handlers, index)
        result = try_handler(handler, email, %{})

        updated_handlers =
          List.update_at(state.handlers, index, fn h ->
            %{h | suspended: true, received: h.received ++ [email]}
          end)

        {result, %{state | handlers: updated_handlers}}
    end
  end

  defp try_match(match, email, state) do
    match.(email, state)
  rescue
    _ -> false
  end

  defp try_handler(handler, email, state) do
    case handler.(email, state) do
      {:ok, _} = ok ->
        {:ok, ok}

      {:reply, _, _} = reply ->
        {:ok, reply}

      other ->
        {:error,
         {RuntimeError.exception("Invalid handler response: #{inspect(other)}"),
          []}}
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end
end
