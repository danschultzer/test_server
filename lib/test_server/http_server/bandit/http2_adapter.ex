# Due to how Bandit HTTP2 handles streams it's necessary to encapsulate the
# calls to ensure that the originating process triggers the plug calls.
#
# We'll wrap the adapter to catch requests meant for `Bandit.HTTP2.Adapter`,
# and send message back to the plug process to ensure all plug calls happen
# in the same process as the initial plug.
#
# This may not be neessary in future releases of Bandit post 1.0.0.
#
# For more background:
# https://github.com/mtrudel/bandit/issues/215
# https://github.com/mtrudel/bandit/issues/101
if Code.ensure_loaded?(Bandit) do
  defmodule TestServer.HTTPServer.Bandit.HTTP2Adapter do
    @moduledoc false

    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def read_req_body({plug_pid, payload}, opts) do
      with {:ok, data, payload} <-
        send_and_receive(plug_pid, :read_req_body, [payload, opts]) do
        {:ok, data, {plug_pid, payload}}
      end
    end

    defp send_and_receive(plug_pid, f, a) do
      mfa = {Bandit.HTTP2.Adapter, f, a}

      send(plug_pid, {self(), mfa})

      receive do
        {:ok, ^mfa, res} -> res
      end
    end

    @impl Plug.Conn.Adapter
    def send_resp({plug_pid, payload}, status, headers, body) do
      with {:ok, sent_body, payload} <-
        send_and_receive(plug_pid, :send_resp, [payload, status, headers, body]) do
        {:ok, sent_body, {plug_pid, payload}}
      end
    end

    @impl Plug.Conn.Adapter
    def send_file({plug_pid, payload}, status, headers, path, offset, length) do
      with {:ok, sent_body, payload} <-
        send_and_receive(plug_pid, :send_file, [payload, status, headers, path, offset, length]) do
        {:ok, sent_body, {plug_pid, payload}}
      end
    end

    @impl Plug.Conn.Adapter
    def send_chunked({plug_pid, payload}, status, headers) do
      with {:ok, sent_body, payload} <-
        send_and_receive(plug_pid, :send_chunked, [payload, status, headers]) do
        {:ok, sent_body, {plug_pid, payload}}
      end
    end

    @impl Plug.Conn.Adapter
    def chunk({plug_pid, payload}, chunk) do
      with {:ok, sent_body, payload} <- send_and_receive(plug_pid, :chunk, [payload, chunk]) do
        {:ok, sent_body, {plug_pid, payload}}
      end
    end

    @impl Plug.Conn.Adapter
    def inform({plug_pid, payload}, status, headers) do
      send_and_receive(plug_pid, :inform, [payload, status, headers])
    end

    @impl Plug.Conn.Adapter
    def upgrade({plug_pid, payload}, upgrade, opts) do
      with {:ok, payload} <- send_and_receive(plug_pid, :upgrade, [payload, upgrade, opts]) do
        {:ok, {plug_pid, payload}}
      end
    end

    @impl Plug.Conn.Adapter
    def push({plug_pid, payload}, path, headers) do
      send_and_receive(plug_pid, :push, [payload, path, headers])
    end

    @impl Plug.Conn.Adapter
    def get_peer_data({plug_pid, payload}) do
      send_and_receive(plug_pid, :get_peer_data, [payload])
    end

    @impl Plug.Conn.Adapter
    def get_http_protocol({plug_pid, payload}) do
      send_and_receive(plug_pid, :get_http_protocol, [payload])
    end
  end
  end
