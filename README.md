# TestServer

[![Github CI](https://github.com/danschultzer/test_server/workflows/CI/badge.svg)](https://github.com/danschultzer/test_server/actions?query=workflow%3ACI)
[![hex.pm](https://img.shields.io/hexpm/v/test_server.svg)](https://hex.pm/packages/test_server)

<!-- MDOC !-->

No fuzz ExUnit test server to mock third party services.

Features:

- HTTP/1
- HTTP/2
- WebSocket
- SSH
- Built-in TLS with self-signed certificates
- Plug route matching

## Protocols

- `TestServer.HTTP` - HTTP/1, HTTP/2, and WebSocket.
- `TestServer.SSH` - SSH commands, authentication, and interactive sessions.

<!-- MDOC !-->

## Installation

Add `test_server` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:test_server, "~> 0.1.22", only: [:test]}
  ]
end
```

## LICENSE

(The MIT License)

Copyright (c) 2022 Dan Schultzer & the Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the 'Software'), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
