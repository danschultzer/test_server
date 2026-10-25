defmodule TestServer.UDP.Instance do
  @moduledoc false

  use GenServer

  alias TestServer.UDP.Server

  @send_timeout 1_000

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @spec register(TestServer.instance(), {:peer, TestServer.stacktrace()}) ::
          {:ok, %{ref: TestServer.UDP.peer_ref()}}
  def register(instance, {:peer, stacktrace}) do
    GenServer.call(instance, {:register, {:peer, stacktrace}})
  end

  @spec register(
          TestServer.instance(),
          {:handle, TestServer.UDP.peer_ref(), keyword(), TestServer.stacktrace()}
        ) :: {:ok, map()}
  def register(instance, {:handle, peer_ref, options, stacktrace}) do
    Keyword.has_key?(options, :to) && ensure_function!(options[:to])
    Keyword.has_key?(options, :match) && ensure_function!(options[:match])

    GenServer.call(instance, {:register, {:handle, peer_ref, options, stacktrace}})
  end

  @spec register(
          TestServer.instance(),
          {:send, TestServer.UDP.peer_ref(), keyword()}
        ) ::
          {:ok, pid()}
          | {:error, :einval}
          | {:error, :enotconn}
          | {:error, :closed}
  def register(instance, {:send, peer_ref, options}) do
    timeout = Keyword.get(options, :timeout, @send_timeout)

    Keyword.has_key?(options, :to) && ensure_function!(options[:to])
    Keyword.has_key?(options, :timeout) && ensure_integer!(timeout)

    GenServer.call(
      instance,
      {:register, {:send, peer_ref, timeout}},
      timeout + 1_000
    )
  end

  defp ensure_function!(fun) when is_function(fun), do: :ok
  defp ensure_function!(fun), do: raise(BadFunctionError, term: fun)

  defp ensure_integer!(value) when is_integer(value) and value > 0, do: :ok

  defp ensure_integer!(value),
    do: raise(ArgumentError, "expected positive integer, got: #{inspect(value)}")

  @spec dispatch(
          TestServer.instance(),
          {:peer, pid(),
           {:udp, :gen_udp.socket(), :inet.ip_address(), :inet.port_number()}
           | {:dtls, :ssl.sslsocket()}}
        ) ::
          {:ok, map(), TestServer.UDP.state()} | {:error, :not_found}
  def dispatch(instance, {:peer, owner, socket}) do
    GenServer.call(instance, {:dispatch, {:peer, owner, socket}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:handle, pid(), TestServer.UDP.data(), TestServer.UDP.state()}
        ) ::
          {:reply, iodata(), TestServer.UDP.state()}
          | {:ok, TestServer.UDP.state()}
          | {:error, :not_found}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:handle, owner, data, peer_state}) do
    GenServer.call(instance, {:dispatch, {:handle, owner, data, peer_state}})
  end

  @spec dispatch(
          TestServer.instance(),
          {:send, keyword(), TestServer.UDP.state(), TestServer.stacktrace()}
        ) ::
          {:reply, iodata(), TestServer.UDP.state()}
          | {:ok, TestServer.UDP.state()}
          | {:error, {term(), TestServer.stacktrace()}}
  def dispatch(instance, {:send, options, peer_state, stacktrace}) do
    Keyword.has_key?(options, :to) && ensure_function!(options[:to])

    GenServer.call(instance, {:dispatch, {:send, options, peer_state, stacktrace}})
  end

  @spec options(TestServer.instance()) :: keyword()
  def options(instance) do
    GenServer.call(instance, :options)
  end

  @spec peers(TestServer.instance()) :: [map()]
  def peers(instance) do
    GenServer.call(instance, :peers)
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
      """
      ##{index + 1}: #{inspect(handler.to)}
          #{Enum.map_join(handler.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
      """
    end)
  end

  @spec format_peers([map()]) :: binary()
  def format_peers(peers) do
    peers
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {peer, index} ->
      """
      ##{index + 1}: #{inspect(peer.ref)}
          #{Enum.map_join(peer.stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
      """
    end)
  end

  @impl true
  def init(options) do
    case Server.start(self(), options) do
      {:ok, options} ->
        {:ok, %{options: options, handlers: [], peers: []}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register, {:peer, stacktrace}}, _from, state) do
    peer = %{
      ref: make_ref(),
      stacktrace: stacktrace,
      owner: nil,
      socket: nil,
      subscribers: []
    }

    {:reply, {:ok, peer}, %{state | peers: state.peers ++ [peer]}}
  end

  def handle_call({:register, {:handle, peer_ref, options, stacktrace}}, _from, state) do
    handler = %{
      peer_ref: peer_ref,
      match: Keyword.get(options, :match),
      to: Keyword.fetch!(options, :to),
      stacktrace: stacktrace,
      suspended: false
    }

    {:reply, {:ok, handler}, %{state | handlers: state.handlers ++ [handler]}}
  end

  def handle_call({:register, {:send, peer_ref, timeout}}, from, state) do
    {index, peer} = find_index_value(state.peers, &(&1.ref == peer_ref))
    alive? = peer && peer.owner && Process.alive?(peer.owner)

    case {peer, alive?} do
      {nil, _} ->
        {:reply, {:error, :einval}, state}

      {%{owner: nil} = peer, _} ->
        timer =
          Process.send_after(
            self(),
            {:timeout, from, {:send, index}},
            timeout
          )

        peer = %{peer | subscribers: peer.subscribers ++ [{from, timer}]}
        peers = List.replace_at(state.peers, index, peer)
        state = %{state | peers: peers}

        {:noreply, state}

      {%{owner: _owner}, false} ->
        {:reply, {:error, :closed}, state}

      {%{owner: owner}, true} ->
        {:reply, {:ok, owner}, state}
    end
  end

  def handle_call({:dispatch, {:peer, owner, socket}}, _from, state) do
    peer =
      Enum.find_index(state.peers, &(&1.owner == owner)) ||
        Enum.find_index(state.peers, &is_nil(&1.owner))

    case peer do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        peer = %{Enum.at(state.peers, index) | owner: owner, socket: socket}
        peer = notify_peer_subscribers(peer, owner)
        peers = List.replace_at(state.peers, index, peer)
        state = %{state | peers: peers}

        {:reply, {:ok, peer, %{}}, state}
    end
  end

  def handle_call({:dispatch, {:handle, owner, data, peer_state}}, _from, state) do
    case Enum.find(state.peers, &(&1.owner == owner)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      peer ->
        {result, state} = run_handlers(data, peer, peer_state, state)

        {:reply, result, state}
    end
  end

  def handle_call(
        {:dispatch, {:send, options, peer_state, stacktrace}},
        _from,
        state
      ) do
    result =
      options
      |> Keyword.fetch!(:to)
      |> try_run_send_handler(peer_state, stacktrace)

    {:reply, result, state}
  end

  def handle_call(option, _from, state) when option in [:peers, :handlers, :options] do
    {:reply, Map.fetch!(state, option), state}
  end

  @impl true
  def handle_info({:timeout, from, {:send, peer_index}}, state) do
    case Enum.at(state.peers, peer_index) do
      %{subscribers: []} ->
        {:noreply, state}

      %{subscribers: subscribers} = peer ->
        subscribers =
          Enum.filter(subscribers, fn {subscriber_from, _timer} ->
            subscriber_from != from
          end)

        peers = List.replace_at(state.peers, peer_index, %{peer | subscribers: subscribers})

        GenServer.reply(from, {:error, :enotconn})

        {:noreply, %{state | peers: peers}}
    end
  end

  defp notify_peer_subscribers(peer, owner) do
    Enum.each(peer.subscribers, fn {from, timer} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:ok, owner})
    end)

    %{peer | subscribers: []}
  end

  defp find_index_value(list, fun) do
    Enum.reduce_while(list, {0, nil}, fn item, {index, nil} ->
      case fun.(item) do
        true -> {:halt, {index, item}}
        false -> {:cont, {index + 1, nil}}
      end
    end)
  end

  defp run_handlers(data, %{ref: peer_ref}, peer_state, state) do
    state.handlers
    |> fetch_match_index([data, peer_state], fn
      %{peer_ref: ^peer_ref, suspended: true} -> false
      %{peer_ref: ^peer_ref, suspended: false} -> true
      %{peer_ref: _other, suspended: _any} -> false
    end)
    |> case do
      {:error, :not_found} ->
        {{:error, :not_found}, state}

      {:error, {error, stacktrace}} ->
        {{:error, {error, stacktrace}}, state}

      {:ok, index} ->
        %{to: handler, stacktrace: stacktrace} = Enum.at(state.handlers, index)

        result = try_run_handler(handler, data, peer_state, stacktrace)

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

  defp try_run_handler(handler, data, peer_state, stacktrace) do
    data
    |> run_handler(handler, peer_state)
    |> validate_handler_response!(stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_handler(data, handler, peer_state) do
    handler.(data, peer_state)
  end

  defp validate_handler_response!(response, stacktrace) do
    case response do
      {:reply, data, state} ->
        {:reply, data, state}

      {:ok, state} ->
        {:ok, state}

      _other ->
        raise """
        Invalid callback response, got: #{inspect(response)}.

        Expected one of the following:

          - {:reply, data, state}, where data is iodata
          - {:ok, state}

        #{Enum.map_join(stacktrace, "\n    ", &Exception.format_stacktrace_entry/1)}
        """
    end
  end

  defp try_run_send_handler(handler, peer_state, stacktrace) do
    handler
    |> run_send_handler(peer_state)
    |> validate_handler_response!(stacktrace)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_send_handler(handler, peer_state) do
    handler.(peer_state)
  end
end
