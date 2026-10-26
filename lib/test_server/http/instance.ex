defmodule TestServer.HTTP.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.HTTP.Server

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(
          TestServer.instance(),
          {:handle, keyword(), TestServer.stacktrace()}
        ) ::
          {:ok, %{ref: TestServer.HTTP.handler_ref()}}
  def register(instance, {:handle, options, stacktrace}) do
    ensure_plug!(options[:to])
    Keyword.has_key?(options, :match) && ensure_function!(options[:match])
    Keyword.has_key?(options, :path) && ensure_binary!(options[:path])
    Keyword.has_key?(options, :method) && ensure_method!(options[:method])

    options = put_match_function(options)

    GenServer.call(instance, {:register, {:handle, options, stacktrace}})
  end

  @spec register(TestServer.instance(), {:plug, atom() | function(), TestServer.stacktrace()}) ::
          {:ok, map()}
  def register(instance, {:plug, plug, stacktrace}) do
    ensure_plug!(plug)

    GenServer.call(instance, {:register, {:plug, plug, stacktrace}})
  end

  @spec register(
          TestServer.instance(),
          {:websocket,
           {:handle, TestServer.HTTP.websocket_ref(), keyword(), TestServer.stacktrace()}}
        ) ::
          {:ok, map()}
  def register(
        instance,
        {:websocket, {:handle, websocket_ref, options, stacktrace}}
      ) do
    Keyword.has_key?(options, :match) && ensure_function!(options[:match])
    ensure_function!(options[:to])

    GenServer.call(
      instance,
      {:register, {:websocket, {:handle, websocket_ref, options, stacktrace}}}
    )
  end

  @spec register(
          TestServer.instance(),
          {:websocket, {:send, TestServer.HTTP.websocket_ref(), keyword()}}
        ) :: {:ok, pid()} | {:error, :einval} | {:error, :enotconn} | {:error, :closed}
  def register(instance, {:websocket, {:send, websocket_ref, options}}) do
    ensure_function!(options[:to])

    GenServer.call(instance, {:register, {:websocket, {:send, websocket_ref, options}}})
  end

  defp ensure_plug!(plug) do
    unless is_function(plug) or (is_atom(plug) and function_exported?(plug, :init, 1)) do
      raise BadFunctionError, term: plug
    end
  end

  defp ensure_binary!(value) when is_binary(value), do: :ok

  defp ensure_binary!(value),
    do: raise(ArgumentError, "expected a binary, got: #{inspect(value)}")

  defp ensure_method!(method) when is_atom(method), do: :ok
  defp ensure_method!(method) when is_list(method), do: :ok

  defp ensure_method!(method),
    do: raise(ArgumentError, "expected :method to be an atom or list, got: #{inspect(method)}")

  defp ensure_function!(fun) when is_function(fun), do: :ok
  defp ensure_function!(fun), do: raise(BadFunctionError, term: fun)

  @spec dispatch(TestServer.instance(), {:plug, Plug.Conn.t()}) ::
          {:ok, Plug.Conn.t()}
          | {:error, {:not_found, Plug.Conn.t()}}
          | {:error, {term(), list()}}
  def dispatch(instance, {:plug, conn}) do
    GenServer.call(instance, {:dispatch, {:plug, conn}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:websocket, {:upgrade, TestServer.HTTP.handler_ref(), pid()}}
        ) ::
          {:ok, TestServer.HTTP.websocket_ref(), TestServer.HTTP.websocket_state()}
  def dispatch(instance, {:websocket, {:upgrade, handler_ref, socket_pid}}) do
    GenServer.call(instance, {:dispatch, {:websocket, {:upgrade, handler_ref, socket_pid}}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:websocket,
           {:handle, TestServer.HTTP.websocket_ref(), TestServer.HTTP.websocket_frame(),
            TestServer.HTTP.websocket_state()}}
        ) ::
          {:ok, TestServer.HTTP.websocket_reply()}
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:websocket, {:handle, websocket_ref, frame, websocket_state}}) do
    GenServer.call(
      instance,
      {:dispatch, {:websocket, {:handle, websocket_ref, frame, websocket_state}}}
    )
  end

  @spec dispatch(
          TestServer.instance(),
          {:websocket,
           {:send, TestServer.HTTP.websocket_ref(), keyword(), TestServer.HTTP.websocket_state(),
            TestServer.stacktrace()}}
        ) ::
          {:ok, TestServer.HTTP.websocket_reply()} | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(
        instance,
        {:websocket, {:send, websocket_ref, options, websocket_state, stacktrace}}
      ) do
    GenServer.call(
      instance,
      {:dispatch, {:websocket, {:send, websocket_ref, options, websocket_state, stacktrace}}}
    )
  end

  @spec options(TestServer.instance()) :: keyword()
  def options(instance) do
    GenServer.call(instance, :options)
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
      methods =
        case handler.methods do
          nil -> "*"
          [] -> "[]"
          methods -> Enum.join(List.wrap(methods), ", ")
        end

      path = handler.path || "*"

      """
      ##{index + 1}: #{methods} #{path}
          #{Enum.map_join(handler.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
      """
    end)
  end

  @spec websocket_handlers(TestServer.instance()) :: [map()]
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

  @impl true
  def init(options) do
    case Server.start(self(), options) do
      {:ok, options} ->
        {:ok,
         %{
           handlers: [],
           plugs: [],
           websockets: [],
           websocket_handlers: [],
           options: options
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register, {:handle, options, stacktrace}}, _from, state) do
    handler = %{
      ref: make_ref(),
      path: Keyword.get(options, :path),
      methods: Keyword.get(options, :method),
      match: Keyword.get(options, :match),
      to: Keyword.fetch!(options, :to),
      websocket: Keyword.get(options, :websocket),
      stacktrace: stacktrace,
      suspended: false
    }

    state =
      case options[:websocket] do
        true ->
          %{
            state
            | websockets:
                state.websockets ++ [%{handler_ref: handler.ref, ref: handler.ref, owner: nil}]
          }

        _false ->
          state
      end

    {:reply, {:ok, handler}, %{state | handlers: state.handlers ++ [handler]}}
  end

  def handle_call({:register, {:plug, plug, stacktrace}}, _from, state) do
    plug = %{plug: plug, stacktrace: stacktrace}

    {:reply, {:ok, plug}, %{state | plugs: state.plugs ++ [plug]}}
  end

  def handle_call(
        {:register, {:websocket, {:handle, websocket_ref, options, stacktrace}}},
        _from,
        state
      ) do
    handler = %{
      websocket_ref: websocket_ref,
      match: Keyword.get(options, :match),
      to: Keyword.fetch!(options, :to),
      stacktrace: stacktrace,
      suspended: false
    }

    {:reply, {:ok, handler}, %{state | websocket_handlers: state.websocket_handlers ++ [handler]}}
  end

  def handle_call({:register, {:websocket, {:send, websocket_ref, _options}}}, _from, state) do
    result =
      case Enum.find(state.websockets, &(&1.ref == websocket_ref)) do
        nil -> {:error, :einval}
        %{owner: nil} -> {:error, :enotconn}
        %{owner: pid} -> (Process.alive?(pid) && {:ok, pid}) || {:error, :closed}
      end

    {:reply, result, state}
  end

  def handle_call(option, _from, state)
      when option in [:options, :handlers, :websocket_handlers] do
    {:reply, Map.fetch!(state, option), state}
  end

  def handle_call({:dispatch, {:plug, conn}}, _from, state) do
    {result, state} =
      conn
      |> run_plugs(state)
      |> run_handlers(state)

    {:reply, result, state}
  end

  def handle_call({:dispatch, {:websocket, {:upgrade, handler_ref, socket_pid}}}, _from, state) do
    index = Enum.find_index(state.websockets, &(&1.handler_ref == handler_ref))
    websocket = %{Enum.at(state.websockets, index) | owner: socket_pid}
    websockets = List.update_at(state.websockets, index, fn _ -> websocket end)

    {:reply, {:ok, websocket.ref, %{}}, %{state | websockets: websockets}}
  end

  def handle_call(
        {:dispatch, {:websocket, {:handle, websocket_ref, frame, websocket_state}}},
        _from,
        state
      ) do
    {res, state} = run_websocket_handlers(websocket_ref, frame, websocket_state, state)

    {:reply, res, state}
  end

  def handle_call(
        {:dispatch, {:websocket, {:send, _websocket_ref, options, websocket_state, stacktrace}}},
        _from,
        state
      ) do
    to = Keyword.fetch!(options, :to)

    result =
      try do
        frame = validate_websocket_frame!(to.(websocket_state), stacktrace)

        {:ok, frame}
      rescue
        error -> {:error, {error, __STACKTRACE__}}
      end

    {:reply, result, state}
  end

  defp put_match_function(options) do
    match_path_fn =
      case Keyword.fetch(options, :path) do
        :error -> nil
        {:ok, path} -> match_path_function(path)
      end

    match_method_fn =
      case Keyword.fetch(options, :method) do
        :error ->
          nil

        {:ok, methods} ->
          methods =
            methods
            |> List.wrap()
            |> Enum.map(&Plug.Router.Utils.normalize_method(&1))

          &(&1.method in methods)
      end

    [
      match_path_fn,
      match_method_fn,
      Keyword.get(options, :match)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        options

      match_fns ->
        Keyword.put(
          options,
          :match,
          fn conn ->
            Enum.all?(match_fns, & &1.(conn))
          end
        )
    end
  end

  defp match_path_function(path) do
    {_params, path_match, guards, _post_match} =
      Plug.Router.Utils.build_path_clause(path, true)

    {match_fn, []} =
      Code.eval_quoted(
        quote do
          fn
            unquote(path_match) when unquote(guards) -> true
            _path -> false
          end
        end
      )

    fn conn ->
      match_fn.(Plug.Router.Utils.decode_path_info!(conn))
    end
  end

  defp run_plugs(conn, state) do
    state.plugs
    |> case do
      [] -> [%{plug: TestServer.HTTP.Plug.default_plug(), stacktrace: nil}]
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
        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
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

  defp run_handlers({:error, error}, state), do: {{:error, error}, state}

  defp run_handlers(conn, state) do
    state.handlers
    |> fetch_match_index([conn], fn
      %{suspended: true} -> false
      %{suspended: false} -> true
    end)
    |> case do
      {:error, :not_found} ->
        {{:error, {:not_found, conn}}, state}

      {:error, {error, stacktrace}} ->
        {{:error, {error, stacktrace}}, state}

      {:ok, index} ->
        %{to: plug, stacktrace: stacktrace} = handler = Enum.at(state.handlers, index)

        result =
          conn
          |> Plug.Conn.put_private(:test_server, %{
            websocket: handler.websocket,
            handler_ref: handler.ref
          })
          |> try_run_plug(plug, stacktrace)

        handler = %{handler | suspended: true}
        handlers = List.replace_at(state.handlers, index, handler)

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

  defp run_websocket_handlers(websocket_ref, frame, websocket_state, state) do
    state.websocket_handlers
    |> fetch_match_index([frame, websocket_state], fn
      %{websocket_ref: ^websocket_ref, suspended: true} -> false
      %{websocket_ref: ^websocket_ref, suspended: false} -> true
      %{websocket_ref: _other_websocket_ref, suspended: _any} -> false
    end)
    |> case do
      {:error, :not_found} ->
        {{:error, :not_found}, state}

      {:error, {error, stacktrace}} ->
        {{:error, {error, stacktrace}}, state}

      {:ok, index} ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.websocket_handlers, index)

        result = try_run_websocket_handler(frame, websocket_state, stacktrace, handler)

        websocket_handlers =
          List.update_at(state.websocket_handlers, index, fn websocket_handle ->
            %{websocket_handle | suspended: true}
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

  defp validate_websocket_frame!({:reply, {opcode, _data}, _state} = response, _stacktrace)
       when opcode in [:text, :binary],
       do: response

  defp validate_websocket_frame!({:ok, _state} = response, _stacktrace), do: response

  defp validate_websocket_frame!(response, stacktrace) do
    raise """
    Invalid callback response, got: #{inspect(response)}.

    Expected one of the following:

      - {:reply, {:text, iodata}, state}
      - {:reply, {:binary, iodata}, state}
      - {:ok, state}

    #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
    """
  end
end
