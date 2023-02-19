## v0.1.9 (2023-02-18)

- `:httpd` server adapter now parses remote ip to tuple format
- `:httpd` server adapter now parses host from host header
- Specifying `:host` now also binds the hostname to IPv6 loopback
- Added `:ipfamily` option to set IP address type to use

## v0.1.8 (2023-02-10)

- Support Bandit and httpd web server
- BREAKING CHANGE: SSL certificate settings have been moved to the `:tls` option

## v0.1.7 (2022-10-06)

- The specified port is checked to ensure is in valid range

## v0.1.6 (2022-09-22)

- Added suspended routes and web socket handlers to error messages

## v0.1.5 (2022-09-13)

- `TestServer.websocket_info/2` now takes the callback function as second argument

## v0.1.4 (2022-09-13)

- WebSocket support

## v0.1.3 (2022-09-12)

- Improved multi-instance handling
- Support for pre-match plugs

## v0.1.2 (2022-09-12)

- Better formatting of errors

## v0.1.1 (2022-09-11)

- `TestServer.url/2` no longer autostarts the test server

## v0.1.0 (2022-09-11)

- Initial release
