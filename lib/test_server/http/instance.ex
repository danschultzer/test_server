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
  def register({TestServer.HTTP, instance_pid}, {:handle, options, stacktrace}) do
    options = put_match_function(options)

    validate_plug!(options, :to)

    GenServer.call(instance_pid, {:register, {:handle, options, stacktrace}})
  end

  @spec register(TestServer.instance(), {:plug, atom() | function(), TestServer.stacktrace()}) ::
          {:ok, map()}
  def register({TestServer.HTTP, instance_pid}, {:plug, plug, stacktrace}) do
    validate_plug!(plug)

    GenServer.call(instance_pid, {:register, {:plug, plug, stacktrace}})
  end

  @spec register(
          TestServer.instance(),
          {:websocket,
           {:handle, TestServer.HTTP.websocket_ref(), keyword(), TestServer.stacktrace()}}
        ) ::
          {:ok, map()} | {:error, :not_found}
  def register(
        {TestServer.HTTP, instance_pid},
        {:websocket, {:handle, websocket_ref, options, stacktrace}}
      ) do
    Keyword.has_key?(options, :match) && validate_function_option!(options, :match, 2)
    validate_function_option!(options, :to, 2)

    GenServer.call(
      instance_pid,
      {:register, {:websocket, {:handle, websocket_ref, options, stacktrace}}}
    )
  end

  @spec register(
          TestServer.instance(),
          {:websocket, {:send, TestServer.HTTP.websocket_ref(), keyword()}}
        ) :: {:ok, pid()} | {:error, :not_found} | {:error, :enotconn} | {:error, :closed}
  def register({TestServer.HTTP, instance_pid}, {:websocket, {:send, websocket_ref, options}}) do
    validate_function_option!(options, :to, 1)

    GenServer.call(instance_pid, {:register, {:websocket, {:send, websocket_ref, options}}})
  end

  defp validate_plug!(plug) do
    case plug?(plug) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "expected a 1-arity function or a Plug module, got: #{inspect(plug)}"
    end
  end

  defp validate_plug!(options, option) do
    plug = Keyword.get(options, option)

    case plug?(plug) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "expected #{inspect(option)} to be a 1-arity function or a Plug module, got: #{inspect(plug)}"
    end
  end

  defp plug?(plug) when is_function(plug, 1), do: true

  defp plug?(plug) do
    is_atom(plug) and
      Code.ensure_loaded?(plug) and
      function_exported?(plug, :init, 1) and
      function_exported?(plug, :call, 2)
  end

  defp validate_function_option!(options, option, arity) do
    value = Keyword.get(options, option)

    case is_function(value, arity) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "expected #{inspect(option)} to be a #{arity}-arity function, got: #{inspect(value)}"
    end
  end

  @spec dispatch(TestServer.instance(), {:plug, Plug.Conn.t()}) ::
          {:ok, Plug.Conn.t()}
          | {:error, {:not_found, Plug.Conn.t()}}
          | {:error, {term(), list()}}
  def dispatch({TestServer.HTTP, instance_pid}, {:plug, conn}) do
    GenServer.call(instance_pid, {:dispatch, {:plug, conn}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:websocket, {:upgrade, TestServer.HTTP.handler_ref(), pid()}}
        ) ::
          {:ok, TestServer.HTTP.websocket_ref(), TestServer.HTTP.websocket_state()}
  def dispatch({TestServer.HTTP, instance_pid}, {:websocket, {:upgrade, handler_ref, socket_pid}}) do
    GenServer.call(instance_pid, {:dispatch, {:websocket, {:upgrade, handler_ref, socket_pid}}})
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
  def dispatch(
        {TestServer.HTTP, instance_pid},
        {:websocket, {:handle, websocket_ref, frame, websocket_state}}
      ) do
    GenServer.call(
      instance_pid,
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
        {TestServer.HTTP, instance_pid},
        {:websocket, {:send, websocket_ref, options, websocket_state, stacktrace}}
      ) do
    GenServer.call(
      instance_pid,
      {:dispatch, {:websocket, {:send, websocket_ref, options, websocket_state, stacktrace}}}
    )
  end

  @spec options(TestServer.instance()) :: keyword()
  def options({TestServer.HTTP, instance_pid}) do
    GenServer.call(instance_pid, :options)
  end

  @spec handlers(TestServer.instance()) :: [map()]
  def handlers({TestServer.HTTP, instance_pid}) do
    GenServer.call(instance_pid, :handlers)
  end

  @spec format_handlers([map()]) :: binary()
  def format_handlers(handlers) do
    handlers
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {handler, index} ->
      methods =
        case handler.methods do
          nil ->
            "any method"

          [] ->
            "no methods"

          methods ->
            methods
            |> List.wrap()
            |> Enum.map_join(" | ", &Plug.Router.Utils.normalize_method/1)
        end

      path = handler.path || "any path"

      """
      ##{index + 1}: #{methods} at #{path}
          #{Enum.map_join(handler.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
      """
    end)
  end

  @spec websocket_handlers(TestServer.instance()) :: [map()]
  def websocket_handlers({TestServer.HTTP, instance_pid}) do
    GenServer.call(instance_pid, :websocket_handlers)
  end

  @spec websockets(TestServer.instance()) :: [map()]
  def websockets({TestServer.HTTP, instance_pid}) do
    GenServer.call(instance_pid, :websockets)
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
    {protocol_module, options} = Keyword.pop!(options, :protocol_module)

    case Server.start({protocol_module, self()}, options) do
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
    case Enum.find(state.websockets, &(&1.ref == websocket_ref)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _websocket ->
        handler = %{
          websocket_ref: websocket_ref,
          match: Keyword.get(options, :match),
          to: Keyword.fetch!(options, :to),
          stacktrace: stacktrace,
          suspended: false
        }

        {:reply, {:ok, handler},
         %{state | websocket_handlers: state.websocket_handlers ++ [handler]}}
    end
  end

  def handle_call({:register, {:websocket, {:send, websocket_ref, _options}}}, _from, state) do
    result =
      case Enum.find(state.websockets, &(&1.ref == websocket_ref)) do
        nil ->
          {:error, :not_found}

        %{owner: nil} ->
          {:error, :enotconn}

        %{owner: owner_pid} ->
          (Process.alive?(owner_pid) && {:ok, owner_pid}) || {:error, :closed}
      end

    {:reply, result, state}
  end

  def handle_call(option, _from, state)
      when option in [:options, :handlers, :websockets, :websocket_handlers] do
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
        frame = validate_websocket_handler_response!(to.(websocket_state), stacktrace)

        {:ok, frame}
      rescue
        error -> {:error, {error, __STACKTRACE__}}
      end

    {:reply, result, state}
  end

  defp put_match_function(options) do
    [
      path_match_function(options),
      method_match_function(options),
      custom_match_function(options)
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

  defp path_match_function(options) do
    case Keyword.fetch(options, :path) do
      :error ->
        nil

      {:ok, path} when is_binary(path) ->
        compile_path_match_function(path)

      {:ok, path} ->
        raise ArgumentError, "expected :path to be a binary, got: #{inspect(path)}"
    end
  end

  defp method_match_function(options) do
    case Keyword.fetch(options, :method) do
      :error ->
        nil

      {:ok, methods} when is_atom(methods) or is_list(methods) ->
        methods =
          methods
          |> List.wrap()
          |> Enum.map(&Plug.Router.Utils.normalize_method(&1))

        &(&1.method in methods)

      {:ok, methods} ->
        raise ArgumentError,
              "expected :method to be an atom or list, got: #{inspect(methods)}"
    end
  end

  defp custom_match_function(options) do
    case Keyword.fetch(options, :match) do
      :error ->
        nil

      {:ok, match_fn} when is_function(match_fn, 1) ->
        match_fn

      {:ok, match} ->
        raise ArgumentError, "expected :match to be a 1-arity function, got: #{inspect(match)}"
    end
  end

  defp compile_path_match_function(path) do
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
      case try_run_plug_handler(conn, plug, stacktrace) do
        {:ok, conn} -> {:cont, conn}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp try_run_plug_handler(conn, plug, stacktrace) do
    conn
    |> run_plug_handler(plug)
    |> validate_plug_handler_response!(plug, stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_plug_handler(conn, plug) when is_function(plug) do
    plug.(conn)
  end

  defp run_plug_handler(conn, plug) when is_atom(plug) do
    options = plug.init([])
    plug.call(conn, options)
  end

  defp validate_plug_handler_response!(response, plug, stacktrace) do
    case response do
      %Plug.Conn{halted: true} ->
        raise """
        cannot halt a connection because all requests must be processed

        # #{inspect(plug)}
            #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """

      %Plug.Conn{halted: false} = conn ->
        {:ok, conn}

      _other ->
        raise """
        expected a Plug.Conn struct, got: #{inspect(response)}

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
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
          |> try_run_plug_handler(plug, stacktrace)

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
      handler
      |> run_websocket_handler(frame, websocket_state)
      |> validate_websocket_handler_response!(stacktrace)

    {:ok, frame}
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_websocket_handler(handler, frame, websocket_state) do
    handler.(frame, websocket_state)
  end

  defp validate_websocket_handler_response!(response, stacktrace) do
    case response do
      {:reply, {opcode, data}, state} when opcode in [:text, :binary] ->
        {:reply, {opcode, data}, state}

      {:ok, state} ->
        {:ok, state}

      _other ->
        raise """
        expected callback response to be one of:

          - {:reply, {:text, iodata}, state}
          - {:reply, {:binary, iodata}, state}
          - {:ok, state}

        Got: #{inspect(response)}

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end
end
