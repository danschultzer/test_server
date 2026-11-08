defmodule TestServer.SSH.SFTPTest do
  use ExUnit.Case

  @ssh_fxp_init 1
  @ssh_fxp_version 2
  @ssh_fxp_open 3
  @ssh_fxp_close 4
  @ssh_fxp_write 6
  @ssh_fxp_stat 17
  @ssh_fxp_status 101
  @ssh_fxp_handle 102
  @ssh_fxp_attrs 105
  @ssh_filexfer_attr_size 1
  @ssh_fx_ok 0

  @sftp_version 3
  @file_content "example content"
  @path "example.txt"
  @file_handle "file-1"

  test ":ssh_sftp.write_file/3" do
    suppress_ssh_strict_kex_ordering_log()

    TestServer.SSH.start!(subsystems: ["sftp"])

    TestServer.SSH.handle(
      to: fn {:data, _channel_id, _data_type_code, data}, state ->
        assert {@ssh_fxp_init, <<version::32>>} = decode_packet(data)
        assert version >= @sftp_version

        response = <<@sftp_version::32>>

        {:reply, encode_packet(@ssh_fxp_version, response), state}
      end
    )

    TestServer.SSH.handle(
      to: fn {:data, _channel_id, _data_type_code, data}, state ->
        assert {@ssh_fxp_open,
                <<request_id::32, path_size::32, received_path::binary-size(path_size),
                  _flags::32, _attributes::binary>>} = decode_packet(data)

        assert received_path == @path

        response =
          <<request_id::32, byte_size(@file_handle)::32, @file_handle::binary>>

        {:reply, encode_packet(@ssh_fxp_handle, response), state}
      end
    )

    TestServer.SSH.handle(
      to: fn {:data, _channel_id, _data_type_code, data}, state ->
        assert {@ssh_fxp_stat,
                <<request_id::32, path_size::32, received_path::binary-size(path_size)>>} =
                 decode_packet(data)

        assert received_path == @path

        response = <<request_id::32, @ssh_filexfer_attr_size::32, 0::64>>

        {:reply, encode_packet(@ssh_fxp_attrs, response), state}
      end
    )

    TestServer.SSH.handle(
      to: fn {:data, _channel_id, _data_type_code, data}, state ->
        assert {@ssh_fxp_write,
                <<request_id::32, handle_size::32, received_handle::binary-size(handle_size),
                  offset::64, content_size::32, content::binary-size(content_size)>>} =
                 decode_packet(data)

        assert received_handle == @file_handle
        assert offset == 0
        assert content == @file_content

        response = <<request_id::32, @ssh_fx_ok::32>>

        {:reply, encode_packet(@ssh_fxp_status, response), state}
      end
    )

    TestServer.SSH.handle(
      to: fn {:data, _channel_id, _data_type_code, data}, state ->
        assert {@ssh_fxp_close,
                <<request_id::32, handle_size::32, received_handle::binary-size(handle_size)>>} =
                 decode_packet(data)

        assert received_handle == @file_handle

        response = <<request_id::32, @ssh_fx_ok::32>>

        {:reply, encode_packet(@ssh_fxp_status, response), state}
      end
    )

    {host, port} = TestServer.SSH.address()
    host = String.to_charlist(host)

    options = [
      connect_timeout: 1_000,
      silently_accept_hosts: true,
      timeout: 1_000,
      user_interaction: false
    ]

    assert {:ok, sftp, connection} = :ssh_sftp.start_channel(host, port, options)
    assert :ssh_sftp.write_file(sftp, String.to_charlist(@path), @file_content) == :ok
    assert :ssh_sftp.stop_channel(sftp) == :ok
    assert :ssh.close(connection) == :ok
  end

  defp suppress_ssh_strict_kex_ordering_log do
    :logger.add_primary_filter(
      __MODULE__,
      {fn
         %{level: :debug, msg: {:string, ~c"client will use strict KEX ordering"}}, _extra ->
           :stop

         _event, _extra ->
           :ignore
       end, []}
    )

    on_exit(fn ->
      :logger.remove_primary_filter(__MODULE__)
    end)
  end

  defp decode_packet(<<size::32, type, payload::binary-size(size - 1)>>),
    do: {type, payload}

  defp encode_packet(type, payload),
    do: <<byte_size(payload) + 1::32, type, payload::binary>>
end
