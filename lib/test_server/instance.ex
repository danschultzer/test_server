defmodule TestServer.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.HTTPServer

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(pid(), {:plug_router_to, {binary(), keyword(), TestServer.stacktrace()}}) ::
          {:ok, %{ref: reference()}}
  def register(instance, {:plug_router_to, {uri, options, stacktrace}}) do
    ensure_plug!(options[:to])
    options[:match] && ensure_function!(options[:match])

    GenServer.call(instance, {:register, {:plug_router_to, {uri, options, stacktrace}}})
  end

  @spec register(pid(), {:plug, {atom() | function(), TestServer.stacktrace()}}) :: {:ok, map()}
  def register(instance, {:plug, {plug, stacktrace}}) do
    ensure_plug!(plug)

    GenServer.call(instance, {:register, {:plug, {plug, stacktrace}}})
  end

  @spec register(
          TestServer.websocket_socket(),
          {:websocket, {:handle, keyword(), TestServer.stacktrace()}}
        ) ::
          {:ok, map()}
  def register({instance, _router_ref} = socket, {:websocket, {:handle, options, stacktrace}}) do
    options[:match] && ensure_function!(options[:match])
    ensure_function!(options[:to])

    GenServer.call(instance, {:register, {:websocket, socket, {:handle, options, stacktrace}}})
  end

  defp ensure_plug!(plug) do
    unless is_function(plug) or (is_atom(plug) and function_exported?(plug, :init, 1)) do
      raise BadFunctionError, term: plug
    end
  end

  defp ensure_function!(fun) when is_function(fun), do: :ok
  defp ensure_function!(fun), do: raise(BadFunctionError, term: fun)

  @spec dispatch(pid(), {:plug, Plug.Conn.t()}) ::
          {:ok, Plug.Conn.t()}
          | {:error, {:not_found, Plug.Conn.t()}}
          | {:error, {term(), list()}}
  def dispatch(instance, {:plug, conn}) do
    GenServer.call(instance, {:dispatch, {:plug, conn}})
  end

  @spec dispatch(
          TestServer.websocket_socket(),
          {:websocket, {:handle, TestServer.websocket_frame()}, TestServer.websocket_state()}
        ) ::
          {:ok, TestServer.websocket_reply()}
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch({instance, _router_ref} = socket, {:websocket, {:handle, frame}, state}) do
    GenServer.call(instance, {:dispatch, {:websocket, socket, {:handle, frame}, state}})
  end

  @spec dispatch(
          TestServer.websocket_socket(),
          {:websocket, {:info, function(), TestServer.stacktrace()}, TestServer.websocket_state()}
        ) ::
          {:ok, TestServer.websocket_reply()}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(
        {instance, _router_ref} = socket,
        {:websocket, {:info, callback, stacktrace}, state}
      ) do
    GenServer.call(
      instance,
      {:dispatch, {:websocket, socket, {:info, callback, stacktrace}, state}}
    )
  end

  @spec get_options(pid()) :: keyword()
  def get_options(instance) do
    GenServer.call(instance, :options)
  end

  @spec routes(pid()) :: [map()]
  def routes(instance) do
    GenServer.call(instance, :routes)
  end

  @spec put_websocket_connection(TestServer.websocket_socket(), pid()) :: :ok
  def put_websocket_connection({instance, route_ref}, pid) do
    GenServer.cast(instance, {:put, :websocket_connection, route_ref, pid})
  end

  @spec active_websocket_connections(TestServer.websocket_socket()) :: [pid()]
  def active_websocket_connections({instance, route_ref}) do
    GenServer.call(instance, {:get, :websocket_connections, route_ref})
  end

  @spec format_routes([map()]) :: binary()
  def format_routes(routes) do
    routes
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {route, index} ->
      """
      ##{index + 1}: #{Enum.join(route.methods, ", ")} #{route.uri}
          #{Enum.map_join(route.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
      """
    end)
  end

  @spec format_instance(pid()) :: binary()
  def format_instance(instance) do
    "#{inspect(__MODULE__)} #{inspect(instance)}"
  end

  @spec websocket_handlers(pid()) :: [map()]
  def websocket_handlers(instance) do
    GenServer.call(instance, :websocket_handlers)
  end

  @spec format_websocket_handlers([map()]) :: binary()
  def format_websocket_handlers(websocket_handlers) do
    websocket_handlers
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {websocket_handle, index} ->
      """
      ##{index + 1}: #{inspect(websocket_handle.to)}
          #{Enum.map_join(websocket_handle.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
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
    init_state = %{
      routes: [],
      plugs: [],
      websocket_handlers: [],
      websocket_connections: [],
      options: options
    }

    case start_http_server(init_state) do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:stop, error}
    end
  end

  defp start_http_server(state) do
    case HTTPServer.start(self(), state.options) do
      {:ok, options} ->
        state = Map.merge(state, %{options: options})

        {:ok, state}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def handle_call({:register, {:plug_router_to, {uri, options, stacktrace}}}, _from, state) do
    methods =
      options
      |> Keyword.get(:via, ["*"])
      |> List.wrap()
      |> Enum.map(&Plug.Router.Utils.normalize_method(&1))

    match = Keyword.get_lazy(options, :match, fn -> build_match_function(uri, methods) end)

    to = Keyword.fetch!(options, :to)

    route = %{
      ref: make_ref(),
      uri: uri,
      methods: methods,
      match: match,
      to: to,
      options: Keyword.drop(options, [:via, :match, :to]),
      requests: [],
      stacktrace: stacktrace,
      suspended: false
    }

    {:reply, {:ok, route}, %{state | routes: state.routes ++ [route]}}
  end

  def handle_call({:register, {:plug, {plug, stacktrace}}}, _from, state) do
    plug = %{plug: plug, stacktrace: stacktrace}

    {:reply, {:ok, plug}, %{state | plugs: state.plugs ++ [plug]}}
  end

  def handle_call(
        {:register, {:websocket, {_instance, route_ref}, {:handle, options, stacktrace}}},
        _from,
        state
      ) do
    handler = %{
      route_ref: route_ref,
      match: Keyword.get(options, :match),
      to: Keyword.fetch!(options, :to),
      options: Keyword.drop(options, [:match, :to]),
      received: [],
      stacktrace: stacktrace,
      suspended: false
    }

    {:reply, {:ok, handler}, %{state | websocket_handlers: state.websocket_handlers ++ [handler]}}
  end

  def handle_call(option, _from, state) when option in [:options, :routes, :websocket_handlers] do
    {:reply, Map.fetch!(state, option), state}
  end

  def handle_call({:get, :websocket_connections, route_ref}, _from, state) do
    connections =
      state.websocket_connections
      |> Enum.filter(&(elem(&1, 0) == route_ref))
      |> Enum.map(&elem(&1, 1))

    {:reply, connections, state}
  end

  def handle_call({:dispatch, {:plug, conn}}, _from, state) do
    {res, state} =
      conn
      |> run_plugs(state)
      |> run_routes(state)

    {:reply, res, state}
  end

  def handle_call(
        {:dispatch, {:websocket, socket, {:handle, frame}, websocket_state}},
        _from,
        state
      ) do
    {res, state} = run_websocket_handlers(socket, frame, websocket_state, state)

    {:reply, res, state}
  end

  def handle_call(
        {:dispatch, {:websocket, _socket, {:info, callback, stacktrace}, websocket_state}},
        _from,
        state
      ) do
    res =
      try do
        frame = validate_websocket_frame!(callback.(websocket_state), stacktrace)

        {:ok, frame}
      rescue
        error -> {:error, {error, __STACKTRACE__}}
      end

    {:reply, res, state}
  end

  defp build_match_function(uri, methods) do
    {method_match, guards} =
      case methods do
        ["*"] ->
          {quote(do: _), true}

        methods ->
          var = quote do: method
          guards = quote(do: unquote(var) in unquote(methods))

          {var, guards}
      end

    {_params, path_match, guards, _post_match} = Plug.Router.Utils.build_path_clause(uri, guards)

    {match_fn, []} =
      Code.eval_quoted(
        quote do
          fn
            _conn, unquote(method_match), unquote(path_match), _host when unquote(guards) -> true
            _conn, _method, _path, _host -> false
          end
        end
      )

    fn conn ->
      match_fn.(conn, conn.method, Plug.Router.Utils.decode_path_info!(conn), conn.host)
    end
  end

  defp run_plugs(conn, state) do
    state.plugs
    |> case do
      [] -> [%{plug: TestServer.Plug.default_plug(), stacktrace: nil}]
      plugs -> plugs
    end
    |> Enum.reduce_while(conn, fn %{plug: plug, stacktrace: stacktrace}, conn ->
      case try_run_plug(conn, plug, stacktrace) do
        {:ok, conn} -> {:cont, conn}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp try_run_plug(conn, plug, stacktrace) do
    conn
    |> run_plug(plug)
    |> check_halted!(plug, stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp check_halted!(%{halted: true}, plug, stacktrace) do
    raise """
    Do not halt a connection. All requests have to be processed.

    # #{inspect(plug)}
        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}")}
    """
  end

  defp check_halted!(conn, _plug, _stacktrace), do: {:ok, conn}

  defp run_plug(conn, plug) when is_function(plug) do
    plug.(conn)
  end

  defp run_plug(conn, plug) when is_atom(plug) do
    options = plug.init([])
    plug.call(conn, options)
  end

  defp run_routes({:error, error}, state), do: {{:error, error}, state}

  defp run_routes(conn, state) do
    state.routes
    |> Enum.find_index(fn
      %{suspended: true} -> false
      %{match: match} -> try_run_match(match, [conn])
    end)
    |> case do
      nil ->
        {{:error, {:not_found, conn}}, state}

      index ->
        %{to: plug, stacktrace: stacktrace} = route = Enum.at(state.routes, index)

        result =
          conn
          |> maybe_put_websocket(route)
          |> try_run_plug(plug, stacktrace)

        routes =
          List.update_at(state.routes, index, fn route ->
            %{route | suspended: true, requests: route.requests ++ [result]}
          end)

        {result, %{state | routes: routes}}
    end
  end

  defp try_run_match(match, args) do
    apply(match, args)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  def maybe_put_websocket(conn, route) do
    case route.options[:websocket] do
      true ->
        websocket = {{self(), route.ref}, Keyword.get(route.options, :init_state)}
        Map.put(conn, :private, %{websocket: websocket})

      _false ->
        conn
    end
  end

  defp run_websocket_handlers({_instance, route_ref}, frame, websocket_state, state) do
    state.websocket_handlers
    |> Enum.map(&{&1.route_ref == route_ref, &1})
    |> Enum.find_index(fn
      {false, _} -> false
      {true, %{suspended: true}} -> false
      {true, %{match: nil}} -> true
      {true, %{match: match}} -> try_run_match(match, [frame, websocket_state])
    end)
    |> case do
      nil ->
        {{:error, :not_found}, state}

      index ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.websocket_handlers, index)

        result = try_run_websocket_handler(frame, websocket_state, stacktrace, handler)

        websocket_handlers =
          List.update_at(state.websocket_handlers, index, fn websocket_handle ->
            %{websocket_handle | suspended: true, received: websocket_handle.received ++ [frame]}
          end)

        {result, %{state | websocket_handlers: websocket_handlers}}
    end
  end

  defp try_run_websocket_handler(frame, websocket_state, stacktrace, handler) do
    frame =
      frame
      |> handler.(websocket_state)
      |> validate_websocket_frame!(stacktrace)

    {:ok, frame}
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp validate_websocket_frame!({:reply, _frame, _state} = response, _stacktrace), do: response
  defp validate_websocket_frame!({:ok, _state} = response, _stacktrace), do: response

  defp validate_websocket_frame!(response, stacktrace) do
    raise """
    Invalid callback response, got: #{inspect(response)}.

    Expected one of the following:

      - {:reply, {:text, message}, state}
      - {:reply, {:binary, message}, state}
      - {:ok, state}

    #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
    """
  end

  @impl true
  def handle_cast({:put, :websocket_connection, route_ref, pid}, state) do
    connections = state.websocket_connections ++ [{route_ref, pid}]

    {:noreply, %{state | websocket_connections: connections}}
  end
end
