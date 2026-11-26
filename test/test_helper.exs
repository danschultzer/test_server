ExUnit.start()

http_server = System.get_env("HTTP_SERVER", "Bandit")

# This ensures that `Bandit.Clock` has started and prevents
# `Header timestamp couldn't be fetched from ETS cache` warnings
if http_server == "Bandit", do: Application.ensure_all_started(:bandit)

http_server = Module.concat(TestServer.HTTP.Server, http_server)

Code.ensure_loaded!(http_server)
Application.put_env(:test_server, :http_server, {http_server, []})

IO.puts("Testing with #{inspect(http_server)}")

# To test with non loopback IP addresses we pull out local IP addresses below
{:ok, interfaces} = :inet.getifaddrs()

private_addresses =
  Enum.flat_map(interfaces, fn {_interface, opts} ->
    opts
    |> Keyword.get_values(:addr)
    |> Enum.filter(fn
      {10, _, _, _} -> true
      {172, b, _, _} when b in 16..31 -> true
      {192, 168, _, _} -> true
      {a, _, _, _, _, _, _, _} when a in 64_512..65_023 -> true
      _ -> false
    end)
  end)

private_inet_ip =
  Enum.find(
    private_addresses,
    {127, 0, 0, 1},
    &match?({_, _, _, _}, &1)
  )

private_inet6_ip =
  Enum.find(
    private_addresses,
    {0, 0, 0, 0, 0, 0, 0, 1},
    &match?({_, _, _, _, _, _, _, _}, &1)
  )

Application.put_env(:test_server, :private_inet_ip, private_inet_ip)
Application.put_env(:test_server, :private_inet6_ip, private_inet6_ip)

IO.puts("Testing with IPv4 address: #{inspect(private_inet_ip)}")
IO.puts("Testing with IPv6 address: #{inspect(private_inet6_ip)}")
