defmodule TestServer.UDP.DNSTest do
  use ExUnit.Case, async: true

  test ":inet_res.lookup/5" do
    TestServer.UDP.handle(
      to: fn data, state ->
        assert {:ok, query} = :inet_dns.decode(data)
        assert header = :inet_dns.msg(query, :header)
        assert [question] = :inet_dns.msg(query, :qdlist)
        assert domain = :inet_dns.dns_query(question, :domain)
        assert domain == ~c"example.test"

        response =
          :inet_dns.make_msg(query,
            header: :inet_dns.make_header(header, qr: true, ra: true),
            anlist: [
              :inet_dns.make_rr(
                domain: domain,
                type: :a,
                class: :in,
                ttl: 60,
                data: {192, 0, 2, 1}
              )
            ]
          )

        {:reply, :inet_dns.encode(response), state}
      end
    )

    {_host, port} = TestServer.UDP.address()

    options = [
      nameservers: [{{127, 0, 0, 1}, port}],
      edns: false,
      retry: 1
    ]

    assert :inet_res.lookup(~c"example.test", :in, :a, options, 1_000) ==
             [{192, 0, 2, 1}]
  end
end
