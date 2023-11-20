# See TestServer.HTTPServer.Bandit.HTTP2Adapter for why this is required.
defmodule TestServer.HTTPServer.Bandit.Plug do
  @moduledoc false

  defdelegate init(opts), to: TestServer.Plug

  def call(%{adapter: {Bandit.HTTP2.Adapter, req}} = conn, {http_server, args, instance}) do
    plug_pid = self()
    conn = %{conn | adapter: {TestServer.HTTPServer.Bandit.HTTP2Adapter, {plug_pid, req}}}

    loop(
      Task.async(fn ->
        conn = call(conn, {http_server, args, instance})

        send(plug_pid, :done)

        %{adapter: {_, {_, req}}} = conn
        %{conn | adapter: {Bandit.HTTP2.Adapter, req}}
      end)
    )
  end

  def call(conn, {http_server, args, instance}) do
    TestServer.Plug.call(conn, {http_server, args, instance})
  end

  defp loop(task) do
    receive do
      :done ->
        Task.await(task)

      {caller, {m, f, a}} ->
        send(caller, {:ok, {m, f, a}, apply(m, f, a)})

        loop(task)
    end
  end
end
