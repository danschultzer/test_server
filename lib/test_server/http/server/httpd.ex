defmodule TestServer.HTTP.Server.Httpd do
  @moduledoc """
  HTTP server adapter using `m::httpd`.

  This adapter will be used by default if there is no `Bandit` or
  `Plug.Cowboy` loaded in the project.

  Chunked responses are buffered until the plug returns, as `m::httpd`
  requires a complete response. This adapter does not stream chunks to the
  client as they are written.

  ## Usage

      TestServer.HTTP.start!(
        http_server: {TestServer.HTTP.Server.Httpd, httpd_options}
      )
  """
  @behaviour TestServer.HTTP.Server

  @impl TestServer.HTTP.Server
  def start(instance, port, scheme, options, httpd_options) do
    httpd_options =
      httpd_options
      |> Keyword.put(:port, port)
      |> Keyword.put(:modules, [__MODULE__])
      |> Keyword.put_new(:server_name, ~c"Httpd Test Server")
      |> Keyword.put_new(:document_root, ~c"/tmp")
      |> Keyword.put_new(:server_root, ~c"/tmp")
      |> Keyword.put_new(:handler_plug, {TestServer.HTTP.Plug, {__MODULE__, [], instance}})
      |> Keyword.put_new(:ipfamily, options[:ipfamily])
      |> put_tls_options(scheme, options[:tls])

    case :inets.start(:httpd, httpd_options) do
      {:ok, server_pid} ->
        stop_on_exit(server_pid, httpd_options)

        {:ok, server_pid, httpd_options}

      {:error, error} ->
        {:error, error}
    end
  end

  defp put_tls_options(httpd_options, :http, _tls_options), do: httpd_options

  defp put_tls_options(httpd_options, :https, tls_options) do
    tls_options = Keyword.put_new(tls_options, :log_level, :warning)

    Keyword.put(httpd_options, :socket_type, {:ssl, tls_options})
  end

  # `:inets` traps exits so we must ensure we stop it explicitly when the
  # instance dies.
  defp stop_on_exit(server_pid, httpd_options) do
    spawn_link(fn ->
      Process.flag(:trap_exit, true)

      receive do
        {:EXIT, _pid, _reason} -> stop(server_pid, httpd_options)
      end
    end)
  end

  @impl TestServer.HTTP.Server
  def stop(server_pid, _httpd_options) do
    :inets.stop(:httpd, server_pid)
  end

  @impl TestServer.HTTP.Server
  def socket_pid(%{adapter: {_, _data}}), do: self()

  # :httpd record handler
  require Record

  Record.defrecordp(
    :httpd,
    Record.extract(:mod, from_lib: "inets/include/httpd.hrl") ++
      [handler_plug: :undefined, websocket: :undefined]
  )

  @doc false
  def unquote(:do)(data) do
    {plug, options} = :httpd_util.lookup(httpd(data, :config_db), :handler_plug)

    data
    |> conn()
    |> plug.call(options)
    |> case do
      %Plug.Conn{adapter: {_, {:websocket, _options, _data}}} ->
        {:proceed, response: {501, ~c"WebSocket is not supported with httpd!"}}

      %Plug.Conn{adapter: {_, {:chunked, status, headers, chunks}}} ->
        {:proceed, response: response(status, headers, chunks)}

      conn ->
        %Plug.Conn{adapter: {_, response}} = maybe_send(conn)

        {:proceed, response: response}
    end
  end

  defp response(status, headers, body) do
    body = IO.iodata_to_binary(body)

    headers =
      headers
      |> put_content_length(status, body)
      |> Enum.map(fn {name, value} ->
        {:binary.bin_to_list(name), :binary.bin_to_list(value)}
      end)
      |> Kernel.++([{:code, status}])

    {:response, headers, body}
  end

  defp put_content_length(headers, status, _body) when status in 100..199 or status == 204 do
    Enum.reject(headers, fn {name, _value} -> name == "content-length" end)
  end

  defp put_content_length(headers, 304, _body), do: headers

  defp put_content_length(headers, _status, body) do
    {_, rest} = Enum.split_with(headers, fn {name, _value} -> name == "content-length" end)

    [{"content-length", to_string(byte_size(body))} | rest]
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
    %{address: remote_ip} = peer_data(data)

    headers =
      data
      |> parsed_header()
      |> Enum.map(fn {name, value} ->
        {IO.iodata_to_binary(name), IO.iodata_to_binary(value)}
      end)

    scheme = scheme(data)
    port = port || ((scheme == :https && 443) || 80)

    %Conn{
      adapter: {__MODULE__, data},
      host: host,
      method: method(data),
      path_info: split_path(path),
      port: port,
      remote_ip: remote_ip,
      query_string: qs,
      req_headers: headers,
      request_path: path,
      scheme: scheme
    }
  end

  defp scheme(data) do
    case scheme_ssl_cert(data) do
      {:https, _ssl_cert} -> :https
      :http -> :http
    end
  end

  defp scheme_ssl_cert(data) do
    case httpd(data, :socket_type) do
      :ip_comm -> :http
      {:ip_comm, _options} -> :http
      {:ssl, options} -> {:https, Keyword.get(options, :cert)}
    end
  end

  defp method(data), do: data |> httpd(:method) |> IO.iodata_to_binary()

  defp request_path(data) do
    data
    |> httpd(:request_uri)
    |> IO.iodata_to_binary()
    |> String.split("?", parts: 2)
    |> case do
      [request_path] -> {request_path, ""}
      [request_path, qs | _] -> {request_path, qs}
    end
  end

  defp host(data) do
    data
    |> httpd(:parsed_header)
    |> Enum.find(&(elem(&1, 0) == ~c"host"))
    |> Kernel.||({~c"host", ~c""})
    |> elem(1)
    |> IO.iodata_to_binary()
    |> case do
      "[" <> _host = host -> :binary.split(host, "]:")
      host -> :binary.split(host, ":")
    end
    |> case do
      [host, port] ->
        [
          host,
          case Integer.parse(port) do
            {port, ""} -> port
            _ -> nil
          end
        ]

      [host] ->
        [host, nil]
    end
    |> case do
      ["[" <> host, port] -> {port, String.trim_trailing(host, "]")}
      [host, port] -> {port, host}
    end
  end

  defp peer_data(data) do
    {:init_data, {port, address}, _, _} = httpd(data, :init_data)
    {:ok, address} = :inet.parse_address(address)
    ssl_cert = ssl_cert(data)

    %{address: address, port: port, ssl_cert: ssl_cert}
  end

  defp ssl_cert(data) do
    case scheme_ssl_cert(data) do
      {:https, ssl_cert} -> ssl_cert
      :http -> nil
    end
  end

  defp parsed_header(data), do: httpd(data, :parsed_header)

  defp split_path(path) do
    segments = :binary.split(path, "/", [:global])
    for segment <- segments, segment != "", do: segment
  end

  @impl Plug.Conn.Adapter
  def send_resp(_data, status, headers, body) do
    body = IO.iodata_to_binary(body)

    {:ok, nil, response(status, headers, body)}
  end

  @impl Plug.Conn.Adapter
  def send_file(_data, status, headers, file, offset, length) do
    content = File.read!(file)
    size = byte_size(content)
    max_length = size - offset
    length = (length == :all && max_length) || length

    offset < 0 && raise ArgumentError, "expected offset to be 0 or greater"
    offset > size && raise ArgumentError, "expected offset to be content size or less"
    length < 0 && raise ArgumentError, "expected length to be 0 or greater"
    length > size && raise ArgumentError, "expected length to be content size or less"

    length > max_length &&
      raise ArgumentError, "expected length to be content size - offset or less"

    content = :binary.part(content, offset, length)

    {:ok, nil, response(status, headers, content)}
  end

  @impl Plug.Conn.Adapter
  def send_chunked(_data, status, headers) do
    {:ok, nil, {:chunked, status, headers, []}}
  end

  @impl Plug.Conn.Adapter
  def chunk({:chunked, status, headers, chunks}, body) do
    {:ok, IO.iodata_to_binary(body), {:chunked, status, headers, [chunks, body]}}
  end

  @impl Plug.Conn.Adapter
  def upgrade(data, :websocket, options) do
    {:ok, {:websocket, options, data}}
  end

  def upgrade(_data, _upgrade, _options), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_http_protocol(data) do
    data
    |> httpd(:http_version)
    |> IO.iodata_to_binary()
    |> String.to_existing_atom()
  end

  @impl Plug.Conn.Adapter
  def read_req_body(data, options) do
    body = IO.iodata_to_binary(httpd(data, :entity_body))
    length = min(byte_size(body), Keyword.get(options, :length, 8_000_000))
    {body, rest} = :erlang.split_binary(body, length)
    data = httpd(data, entity_body: rest)

    case rest do
      "" -> {:ok, body, data}
      _rest -> {:more, body, data}
    end
  end

  @impl Plug.Conn.Adapter
  def get_peer_data(data), do: peer_data(data)

  # Unsupported HTTP/2 features

  @impl Plug.Conn.Adapter
  def push(_data, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def inform(_data, _status, _headers), do: {:error, :not_supported}
end
