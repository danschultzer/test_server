if Code.ensure_loaded?(:httpd) do
  defmodule TestServer.HTTPServer.Httpd do
    @moduledoc """
    HTTP server adapter using `:httpd`.

    This adapter will be used by default if there is no `Bandit` or
    `Plug.Cowboy` loaded in the project.

    ## Usage

        TestServer.start(
          http_server: {TestServer.HTTPServer.Httpd, httpd_options}
        )
    """
    @behaviour TestServer.HTTPServer

    @impl TestServer.HTTPServer
    def start(instance, port, scheme, options, httpd_options) do
      httpd_options =
        httpd_options
        |> Keyword.put(:port, port)
        |> Keyword.put(:modules, [__MODULE__])
        |> Keyword.put_new(:server_name, ~c"Httpd Test Server")
        |> Keyword.put_new(:document_root, ~c"/tmp")
        |> Keyword.put_new(:server_root, ~c"/tmp")
        |> Keyword.put_new(:handler_plug, {TestServer.Plug, {__MODULE__, [], instance}})
        |> Keyword.put_new(:ipfamily, options[:ipfamily])
        |> put_tls_options(scheme, options[:tls])

      case :inets.start(:httpd, httpd_options) do
        {:ok, pid} -> {:ok, pid, httpd_options}
        {:error, error} -> {:error, error}
      end
    end

    defp put_tls_options(httpd_options, :http, _tls_options), do: httpd_options

    defp put_tls_options(httpd_options, :https, tls_options) do
      tls_options = Keyword.put_new(tls_options, :log_level, :warning)

      Keyword.put(httpd_options, :socket_type, {:ssl, tls_options})
    end

    @impl TestServer.HTTPServer
    def stop(pid, _httpd_options) do
      :inets.stop(:httpd, pid)
    end

    @impl TestServer.HTTPServer
    def get_socket_pid(conn), do: conn.owner

    # :httpd record handler
    require Record

    Record.defrecordp(
      :httpd,
      Record.extract(:mod, from_lib: "inets/include/httpd.hrl") ++
        [handler_plug: :undefined, websocket: :undefined]
    )

    @doc false
    def unquote(:do)(data) do
      {plug, opts} = :httpd_util.lookup(httpd(data, :config_db), :handler_plug)

      data
      |> conn()
      |> plug.call(opts)
      |> handle_websocket()
    end

    defp handle_websocket(%Plug.Conn{adapter: {_adapter, {:websocket, _opts, _data}}}) do
      {:proceed, response: {422, ~c"WebSocket is not supported with httpd!"}}
    end

    defp handle_websocket(conn) do
      %Plug.Conn{adapter: {_, response}} = maybe_send(conn)

      {:proceed, response: response}
    end

    defp maybe_send(%Plug.Conn{state: :unset}), do: raise(Plug.Conn.NotSentError)
    defp maybe_send(%Plug.Conn{state: :set} = conn), do: Plug.Conn.send_resp(conn)
    defp maybe_send(%Plug.Conn{} = conn), do: conn

    # Plug.Conn adapter

    @behaviour Plug.Conn.Adapter

    alias Plug.Conn

    defp conn(data) do
      {path, qs} = request_path(data)
      {port, host} = host(data)
      {_port, remote_ip} = peer(data)
      {:ok, remote_ip} = :inet.parse_address(remote_ip)

      headers = Enum.map(parsed_header(data), &{to_string(elem(&1, 0)), to_string(elem(&1, 1))})

      %Conn{
        adapter: {__MODULE__, data},
        host: to_string(host),
        method: to_string(method(data)),
        owner: self(),
        path_info: split_path(to_string(path)),
        port: port,
        remote_ip: remote_ip,
        query_string: qs,
        req_headers: headers,
        request_path: path,
        scheme: nil
      }
    end

    defp method(data), do: httpd(data, :method)

    defp request_path(data) do
      data
      |> httpd(:request_uri)
      |> to_string()
      |> String.split("?")
      |> case do
        [request_path] -> {request_path, ""}
        [request_path, qs] -> {request_path, qs}
      end
    end

    defp host(data) do
      data
      |> httpd(:parsed_header)
      |> Enum.find(&(elem(&1, 0) == ~c"host"))
      |> Kernel.||({~c"host", ~c""})
      |> elem(1)
      |> to_string()
      |> :binary.split(":")
      |> case do
        [host, port] ->
          {Integer.parse(port), host}

        [host] ->
          {nil, host}
      end
    end

    defp peer(data) do
      {:init_data, peer, _, _} = httpd(data, :init_data)

      peer
    end

    defp parsed_header(data), do: httpd(data, :parsed_header)

    defp split_path(path) do
      segments = :binary.split(path, "/", [:global])
      for segment <- segments, segment != "", do: segment
    end

    @impl Plug.Conn.Adapter
    def send_resp(_data, status, headers, body) do
      body = String.to_charlist(body)

      headers =
        headers
        |> Kernel.++([{"content-length", to_string(length(body))}])
        |> Enum.map(&{String.to_charlist(elem(&1, 0)), String.to_charlist(elem(&1, 1))})
        |> Kernel.++([{:code, status}])

      {:ok, nil, {:response, headers, body}}
    end

    @impl Plug.Conn.Adapter
    def upgrade(data, :websocket, opts) do
      {:ok, {:websocket, opts, data}}
    end

    def upgrade(_data, _upgrade, _opts), do: {:error, :not_supported}

    @impl Plug.Conn.Adapter
    def get_http_protocol(data), do: httpd(data, :http_version)

    @impl Plug.Conn.Adapter
    def read_req_body(data, _opts), do: {:ok, to_string(httpd(data, :entity_body)), data}

    # Callbacks yet to be implemented

    @impl Plug.Conn.Adapter
    def send_file(_, _, _, _, _, _), do: {:ok, nil, nil}

    @impl Plug.Conn.Adapter
    def send_chunked(_, _, _), do: {:ok, nil, nil}

    @impl Plug.Conn.Adapter
    def chunk(_, _), do: {:error, :not_implemented}

    @impl Plug.Conn.Adapter
    def push(_, _, _), do: {:error, :not_implemented}

    @impl Plug.Conn.Adapter
    def inform(_, _, _), do: {:error, :not_implemented}

    @impl Plug.Conn.Adapter
    def get_peer_data(_), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}
  end
end
