# See TestServer.HTTP.Server.Bandit.Adapter for why this is required.
if Code.ensure_loaded?(Bandit) do
  defmodule TestServer.HTTP.Server.Bandit.Plug do
    @moduledoc false

    defdelegate init(options), to: TestServer.HTTP.Plug

    def call(%{adapter: {Bandit.Adapter, adapter}} = conn, {http_server, args, instance}) do
      plug_pid = self()
      conn = %{conn | adapter: {TestServer.HTTP.Server.Bandit.Adapter, {plug_pid, adapter}}}

      task =
        Task.async(fn ->
          conn = TestServer.HTTP.Plug.call(conn, {http_server, args, instance})

          send(plug_pid, :done)

          conn
        end)

      receive_messages(task, adapter)
    end

    # Bandit keeps its request body state in the adapter. Preserve the latest
    # adapter even when a handler ignores the conn returned by an adapter call.
    defp receive_messages(task, adapter) do
      receive do
        :done ->
          conn = Task.await(task)
          %{conn | adapter: {Bandit.Adapter, adapter}}

        {caller, {m, f, a}} when is_atom(m) and is_atom(f) and is_list(a) ->
          result = apply(m, f, a)
          send(caller, {:ok, {m, f, a}, result})

          receive_messages(task, get_adapter(result) || adapter)
      end
    end

    defp get_adapter({:ok, _body, %Bandit.Adapter{} = adapter}), do: adapter
    defp get_adapter({:more, _body, %Bandit.Adapter{} = adapter}), do: adapter
    defp get_adapter({:ok, %Bandit.Adapter{} = adapter}), do: adapter
    defp get_adapter(_result), do: nil
  end
end
