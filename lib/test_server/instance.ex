defmodule TestServer.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.Plug.Cowboy

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def stop(instance) do
    GenServer.stop(instance)
  end

  @spec register(pid(), {binary(), keyword(), list()}) :: :ok
  def register(instance, {uri, options, stacktrace}) do
    unless is_atom(options[:to]) or is_function(options[:to]),
      do: raise(BadFunctionError, term: options[:to])

    unless is_nil(options[:match]) or is_function(options[:match]),
      do: raise(BadFunctionError, term: options[:match])

    GenServer.call(instance, {:register, {uri, options, stacktrace}})
  end

  @spec dispatch(pid(), Plug.Conn.t()) ::
          {:ok, Plug.Conn.t()} | {:error, :not_found} | {:error, {term(), list()}}
  def dispatch(instance, conn) do
    GenServer.call(instance, {:dispatch, conn})
  end

  @spec get_options(pid()) :: keyword()
  def get_options(instance) do
    GenServer.call(instance, :options)
  end

  @spec active_routes(pid()) :: [map()]
  def active_routes(instance) do
    instance
    |> GenServer.call(:routes)
    |> Enum.reject(& &1.suspended)
  end

  @spec format_routes([map()]) :: binary()
  def format_routes([]), do: "None"

  def format_routes(routes) do
    routes
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {route, index} ->
      """
      ##{index + 1}: #{Enum.join(route.methods, ", ")} #{route.uri}
          #{Exception.format_stacktrace_entry(List.first(route.stacktrace))}")}
      """
    end)
  end

  @spec report_error(pid(), {struct(), list()}) :: :ok
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
    init_state = %{routes: [], options: options}

    case start_cowboy(init_state) do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:stop, error}
    end
  end

  defp start_cowboy(state) do
    case Cowboy.start(self(), state.options) do
      {:ok, cowboy, options} ->
        state = Map.merge(state, %{options: options, cowboy_pid: cowboy})

        {:ok, state}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def handle_call({:register, {uri, options, stacktrace}}, _from, state) do
    methods =
      options
      |> Keyword.get(:via, ["*"])
      |> List.wrap()
      |> Enum.map(&Plug.Router.Utils.normalize_method(&1))

    match = Keyword.get_lazy(options, :match, fn -> build_match_function(uri, methods) end)

    routes =
      state.routes ++
        [
          %{
            uri: uri,
            methods: methods,
            match: match,
            to: Keyword.fetch!(options, :to),
            options: options,
            requests: [],
            stacktrace: stacktrace,
            suspended: false
          }
        ]

    {:reply, :ok, %{state | routes: routes}}
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

  def handle_call(:options, _from, state) do
    {:reply, state.options, state}
  end

  def handle_call(:routes, _from, state) do
    {:reply, state.routes, state}
  end

  def handle_call({:dispatch, conn}, _from, state) do
    state.routes
    |> Enum.find_index(&matches?(&1, conn))
    |> case do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        result =
          try do
            {:ok, run_plug(Enum.at(state.routes, index), conn)}
          rescue
            error -> {:error, {error, __STACKTRACE__}}
          end

        routes =
          List.update_at(state.routes, index, fn route ->
            %{route | suspended: true, requests: route.requests ++ [result]}
          end)

        {:reply, result, %{state | routes: routes}}
    end
  end

  defp matches?(%{suspended: true}, _conn), do: false

  defp matches?(%{match: match}, conn) do
    match.(conn)
  end

  defp run_plug(%{to: to}, conn) when is_function(to) do
    to.(conn)
  end

  defp run_plug(%{to: plug}, conn) when is_atom(plug) do
    options = plug.init([])
    plug.call(conn, options)
  end
end
