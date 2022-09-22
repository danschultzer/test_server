defmodule TestServer.Plug.Cowboy.Plug do
  @moduledoc false

  alias Plug.Conn
  alias TestServer.Instance

  def init([instance]), do: instance

  def call(conn, instance) do
    case Instance.dispatch(instance, {:plug, conn}) do
      {:ok, %{adapter: {adapter, req}, private: %{websocket: {socket, state}}} = conn} ->
        conn
        |> Map.put(:state, :chunked)
        |> Map.put(:adapter, {adapter, {:websocket, req, {socket, state}}})

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
    routes = Enum.split_with(Instance.routes(instance), &(not &1.suspended))

    """
    #{message}

    #{format_routes(routes)}
    """
  end

  defp format_routes({[], suspended_routes}) do
    message = "No active routes."

    case suspended_routes do
      [] ->
        message

      suspended_routes ->
        """
        #{message} The following routes have been processed:

        #{Instance.format_routes(suspended_routes)}
        """
    end
  end

  defp format_routes({active_routes, _suspended_routes}) do
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
