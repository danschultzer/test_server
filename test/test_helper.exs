ExUnit.start()

http_server = System.get_env("HTTP_SERVER", "Bandit")

# This ensures that `Bandit.Clock` has started and prevents
# `Header timestamp couldn't be fetched from ETS cache` warnings
if http_server == "Bandit", do: Application.ensure_all_started(:bandit)

http_server = Module.concat(TestServer.HTTPServer, http_server)
Application.put_env(:test_server, :http_server, {http_server, []})
IO.puts("Testing with #{inspect http_server}")
