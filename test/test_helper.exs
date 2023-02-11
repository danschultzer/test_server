ExUnit.start()

if http_server = System.get_env("HTTP_SERVER") do
  http_server = Module.concat(TestServer.HTTPServer, http_server)
  Application.put_env(:test_server, :http_server, {http_server, []})
  IO.puts("Testing with #{inspect http_server}")
end
