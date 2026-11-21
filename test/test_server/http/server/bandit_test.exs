defmodule TestServer.HTTP.Server.BanditTest do
  use ExUnit.Case
  doctest TestServer.HTTP.Server.Bandit

  describe "start!/1" do
    test "with `:http_server` option" do
      http_server =
        {
          TestServer.HTTP.Server.Bandit,
          thousand_island_options: [transport_options: [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}]]
        }

      TestServer.HTTP.start!(http_server: http_server)

      TestServer.HTTP.handle(
        to: fn conn ->
          assert %{address: address} = Plug.Conn.get_sock_data(conn)
          assert address == {0, 0, 0, 0, 0, 0, 0, 1}
          assert conn.remote_ip == {0, 0, 0, 0, 0, 0, 0, 1}

          Plug.Conn.resp(conn, 200, "OK")
        end
      )

      url = String.to_charlist(TestServer.HTTP.url())

      assert :ok = :httpc.set_options(ipfamily: :inet6)
      assert {:ok, {{_, status_code, _}, _, body}} = :httpc.request(:get, {url, []}, [], [])
      assert status_code == 200
      assert body == ~c"OK"
    end
  end
end
