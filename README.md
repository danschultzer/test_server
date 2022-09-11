# TestServer

<!-- MDOC !-->

No fuzz ExUnit test server to mock third party services.

Features:

* HTTP/1
* HTTP/2
* Built-in TLS with self-signed certificates
* Plug route matching

<!-- MDOC !-->

## Installation

Add `test_server` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:test_server, "~> 0.1.0", only: [:test]}
  ]
end
```

## Usage

```elixir
test "fetch_url/0" do
  # The test server will autostart the current test, if not already running
  TestServer.add("/", via: :get)

  # The URL is derrived from the current test server instance
  Application.put_env(:my_app, :fetch_url, TestServer.url())

  {:ok, "HTTP"} = MyModule.fetch_url()
end
```

The `TestServer.add/2` function can route a request to an anonymous function:

```elixir
TestServer.add("/", to: fn conn ->
  Conn.send_resp(conn, 200, "success")
end)
```

It can also route to a plug:

```elixir
TestServer.add("/", to: MyPlug)
```

The method to listen to can be defined with `:via`, by default it'll match any method:

```elixir
TestServer.add("/", via: :post)
```

A custom match function can be set with `:match` option:

```elixir
TestServer.add("/", match: fn
  %{params: %{"a" => 1}} = _conn -> true
  _conn -> false
end)
```

By default all routes are served as plain HTTP.

HTTPS can be enabled with the `:scheme` option when starting the test server. The certificate suite is will automatically be generated.

```elixir
{:ok, instance} = TestServer.start(scheme: :https)
cacerts = TestServer.x509_suite().cacerts
```

Custom SSL certificates can also be used by defining the cowboy options:

```elixir
TestServer.start(scheme: :https, cowboy_options: [keyfile: key, certfile: cert])
```

When a route is matched it'll be removed from active routes list. The route will be triggered in the order they where added:

```elixir
TestServer.add("/", via: :get, &Conn.send_resp(&1, 200, "first"))
TestServer.add("/", via: :get, &Conn.send_resp(&1, 200, "second"))

{:ok, "first"} = fetch_request()
{:ok, "second"} = fetch_request()
```

<!-- MDOC !-->

## LICENSE

(The MIT License)

Copyright (c) 2022 Dan Schultzer & the Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the 'Software'), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
