# See TestServer.HTTP.Server.Bandit.Adapter for why this is required.
defmodule TestServer.HTTP.Server.Bandit.Plug do
  @moduledoc false

  defdelegate init(options), to: TestServer.HTTP.Plug

  def call(%{adapter: {Bandit.Adapter, req}} = conn, {http_server, args, instance}) do
    plug_pid = self()
    conn = %{conn | adapter: {TestServer.HTTP.Server.Bandit.Adapter, {plug_pid, req}}}

    loop(
      Task.async(fn ->
        conn = call(conn, {http_server, args, instance})
        send(plug_pid, :done)
        conn
      end),
      req
    )
  end

  def call(conn, {http_server, args, instance}) do
    TestServer.HTTP.Plug.call(conn, {http_server, args, instance})
  end

  # TestServer's docs and tests shows handlers discarding the conn returned by `Plug.Conn.read_body/2`.
  # With Bandit the adapter state (e.g. `unread_content_length`) is kept in the conn,
  # and if such a stale conn suggesting undrained body reaches `Bandit.Pipeline.commit_response!/1`
  # it drains the *next* request off the keep-alive connection.
  # We therefore need to preserve the adapter state after each call and hand that same state back on the final conn.
  defp loop(task, req) do
    receive do
      :done ->
        conn = Task.await(task)
        %{conn | adapter: {Bandit.Adapter, req}}

      {caller, {m, f, a}} when is_atom(m) and is_atom(f) and is_list(a) ->
        res = apply(m, f, a)
        send(caller, {:ok, {m, f, a}, res})

        loop(task, next_req(f, res, req))
    end
  end

  # these callbacks return updated adapter state
  defp next_req(:read_req_body, {:ok, _body, adapter}, _), do: adapter
  defp next_req(:read_req_body, {:more, _body, adapter}, _), do: adapter
  defp next_req(:send_resp, {:ok, _body, adapter}, _), do: adapter
  defp next_req(:send_file, {:ok, _body, adapter}, _), do: adapter
  defp next_req(:send_chunked, {:ok, _body, adapter}, _), do: adapter
  defp next_req(:chunk, {:ok, _body, adapter}, _), do: adapter
  defp next_req(:inform, {:ok, adapter}, _), do: adapter
  defp next_req(:upgrade, {:ok, adapter}, _), do: adapter

  # other callbacks either return an error or read-only data
  defp next_req(_f, _res, adapter), do: adapter
end
