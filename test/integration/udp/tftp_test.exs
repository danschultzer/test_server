defmodule TestServer.UDP.TFTPTest do
  use ExUnit.Case, async: true

  test ":tftp.read_file/3" do
    file_content = String.duplicate("a", 513)

    TestServer.UDP.handle(
      to: fn data, state ->
        assert <<1::16, request::binary>> = data

        assert ["example.txt", "octet", "timeout", "1"] =
                 :binary.split(request, <<0>>, [:global, :trim])

        {:reply, <<6::16, "timeout", 0, "1", 0>>, state}
      end
    )

    TestServer.UDP.handle(
      to: fn data, state ->
        assert data == <<4::16, 0::16>>

        content = String.slice(file_content, 0, 512)

        {:reply, <<3::16, 1::16, content::binary>>, state}
      end
    )

    TestServer.UDP.handle(
      to: fn data, state ->
        assert data == <<4::16, 1::16>>

        content = String.slice(file_content, 512, 1)

        {:reply, <<3::16, 2::16, content::binary>>, state}
      end
    )

    TestServer.UDP.handle(
      to: fn data, state ->
        assert data == <<4::16, 2::16>>

        {:ok, state}
      end
    )

    {host, port} = TestServer.UDP.address()
    options = [host: String.to_charlist(host), port: port] ++ [{~c"timeout", ~c"1"}]

    assert :tftp.read_file(~c"example.txt", :binary, options) == {:ok, file_content}
  end
end
