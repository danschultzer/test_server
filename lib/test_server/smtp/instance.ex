defmodule TestServer.SMTP.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.SMTP.Server

  @default_ok_response "250 2.0.0 Ok"
  @default_error_response "550 5.0.0 Rejected"

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(pid(), {keyword(), TestServer.stacktrace()}) :: {:ok, map()}
  def register(instance, {options, stacktrace}) do
    to = Keyword.get(options, :to)
    to && ensure_function!(to, 2)
    match = Keyword.get(options, :match)
    match && ensure_function!(match, 2)

    GenServer.call(instance, {:register, {options, stacktrace}})
  end

  defp ensure_function!(fun, arity) when is_function(fun, arity), do: :ok

  defp ensure_function!(fun, arity) do
    raise ArgumentError,
          "expected a function with arity #{arity}, got: #{inspect(fun)}"
  end

  @spec dispatch(pid(), TestServer.SMTP.Email.t()) ::
          {:ok, binary()} | {:error, :not_found} | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, email) do
    GenServer.call(instance, {:dispatch, email})
  end

  @spec check_credentials(pid(), binary(), binary()) :: boolean()
  def check_credentials(instance, username, password) do
    GenServer.call(instance, {:check_credentials, username, password})
  end

  @spec has_credentials?(pid()) :: boolean()
  def has_credentials?(instance) do
    GenServer.call(instance, :has_credentials?)
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
    Process.flag(:trap_exit, true)

    port = Keyword.get(options, :port, 0)
    hostname = Keyword.get(options, :hostname, "localhost")
    tls = Keyword.get(options, :tls, false)
    credentials = Keyword.get(options, :credentials, [])

    {x509_suite, tls_options} = maybe_generate_x509(tls)

    server_opts = [
      port: port,
      hostname: hostname,
      tls_options: tls_options
    ]

    {:ok, _server_pid} = Server.start_link(self(), server_opts)

    receive do
      {:listening, actual_port, listen_socket} ->
        options =
          options
          |> Keyword.put(:port, actual_port)
          |> Keyword.put(:hostname, hostname)

        {:ok,
         %{
           options: options,
           listen_socket: listen_socket,
           credentials: credentials,
           x509_suite: x509_suite,
           handlers: []
         }}
    after
      5_000 ->
        {:stop, :timeout}
    end
  end

  defp maybe_generate_x509(true) do
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
    handler = %{
      ref: make_ref(),
      match: Keyword.get(options, :match),
      to: Keyword.get(options, :to, &default_handler/2),
      stacktrace: stacktrace,
      suspended: false,
      received: []
    }

    {:reply, {:ok, handler}, %{state | handlers: state.handlers ++ [handler]}}
  end

  def handle_call({:dispatch, email}, _from, state) do
    {result, state} = run_handlers(email, state)
    {:reply, result, state}
  end

  def handle_call({:check_credentials, username, password}, _from, state) do
    result =
      Enum.any?(state.credentials, fn
        {^username, ^password} -> true
        _ -> false
      end)

    {:reply, result, state}
  end

  def handle_call(:has_credentials?, _from, state) do
    {:reply, state.credentials != [], state}
  end

  def handle_call(:handlers, _from, state) do
    {:reply, state.handlers, state}
  end

  def handle_call(:options, _from, state) do
    {:reply, state.options, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:listening, _port, _socket}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state[:listen_socket] do
      :gen_tcp.close(state.listen_socket)
    end

    :ok
  end

  # Handler dispatch

  defp run_handlers(email, state) do
    state.handlers
    |> Enum.find_index(fn
      %{suspended: true} -> false
      %{match: nil} -> true
      %{match: match} -> try_match(match, email)
    end)
    |> case do
      nil ->
        {{:error, :not_found}, state}

      index ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.handlers, index)

        result = try_dispatch(handler, email, stacktrace)

        handlers =
          List.update_at(state.handlers, index, fn h ->
            %{h | suspended: result_ok?(result), received: h.received ++ [email]}
          end)

        {to_smtp_result(result), %{state | handlers: handlers}}
    end
  end

  defp try_match(match, email) do
    match.(email, %{})
  rescue
    FunctionClauseError -> false
  end

  defp try_dispatch(handler, email, stacktrace) do
    response =
      email
      |> handler.(%{})
      |> validate_response!(stacktrace)

    {:ok, response}
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp to_smtp_result({:ok, response}), do: {:ok, response}
  defp to_smtp_result({:error, _} = error), do: error

  defp result_ok?({:ok, _}), do: true
  defp result_ok?(_), do: false

  defp validate_response!({:ok, state}, _stacktrace) when is_map(state) or is_nil(state),
    do: @default_ok_response

  defp validate_response!({:ok, message, _state}, _stacktrace) when is_binary(message),
    do: message

  defp validate_response!({:error, state}, _stacktrace) when is_map(state) or is_nil(state),
    do: @default_error_response

  defp validate_response!({:error, message, _state}, _stacktrace) when is_binary(message),
    do: message

  defp validate_response!(response, stacktrace) do
    raise """
    Invalid callback response, got: #{inspect(response)}.

    Expected one of the following:

      - {:ok, state}
      - {:ok, "250 Custom message", state}
      - {:error, state}
      - {:error, "550 Custom error", state}

    #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
    """
  end

  defp default_handler(_email, state), do: {:ok, state}
end
