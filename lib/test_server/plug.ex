defmodule TestServer.Plug do
  @moduledoc false

  alias Plug.Conn
  alias TestServer.Instance

  def init({http_server, args, instance}), do: {http_server, args, instance}

  def call(conn, {http_server, args, instance}) do
    case Instance.dispatch(instance, {:plug, conn}) do
      {:ok, %{state: :unset, private: %{websocket: {socket, state}}} = conn} ->
        :ok = Instance.put_websocket_connection(socket, http_server.get_socket_pid(conn))
        Plug.Conn.upgrade_adapter(conn, :websocket, {http_server, {socket, state}, args})

      {:ok, conn} ->
        conn

      {:error, {:not_found, conn}} ->
        message =
          "#{Instance.format_instance(instance)} received an unexpected #{conn.method} request at #{conn.request_path}"
          |> append_formatted_params(conn)
          |> append_formatted_routes(instance)

        resp_error(conn, instance, {RuntimeError.exception(message), []})

      {:error, {error, stacktrace}} ->
        resp_error(conn, instance, {error, stacktrace})
    end
  end

  defp append_formatted_params(message, conn) do
    conn
    |> Map.take([:query_params, :body_params])
    |> Enum.filter(fn
      {_key, %Conn.Unfetched{}} -> false
      {_key, empty} when empty == %{} -> false
      {_key, params} when is_map(params) -> true
    end)
    |> case do
      [] -> message <> "."
      params -> message <> " with params:\n\n#{inspect(Map.new(params), pretty: true)}"
    end
  end

  defp append_formatted_routes(message, instance) do
    routes = Enum.split_with(Instance.routes(instance), &Instance.active_route?/1)

    """
    #{message}

    #{format_routes(routes)}
    """
  end

  defp format_routes({[], exhausted_routes}) do
    message = "No active routes."

    case exhausted_routes do
      [] ->
        message

      exhausted_routes ->
        """
        #{message} The following routes have been processed:

        #{Instance.format_routes(exhausted_routes)}
        """
    end
  end

  defp format_routes({active_routes, _exhausted_routes}) do
    """
    Active routes:

    #{Instance.format_routes(active_routes)}
    """
  end

  defp resp_error(conn, instance, {exception, stacktrace}) do
    Instance.report_error(instance, {exception, stacktrace})

    Conn.send_resp(conn, 500, Exception.format(:error, exception, stacktrace))
  end

  def default_plug, do: &Conn.fetch_query_params/1
end
