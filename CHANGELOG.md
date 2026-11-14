# Changelog

## Unreleased

*This release contains breaking changes.*

Requires Elixir 1.15 or higher.

### Breaking changes

- Moved all public functions from `TestServer` to `TestServer.HTTP`
- Moved HTTP server adapters from `TestServer.HTTPServer.*` to `TestServer.HTTP.Server.*`
- Renamed `add/1` to `TestServer.HTTP.handle/1`; it now accepts the `:method` option instead of `:via` and no longer accepts binary method value such as `"POST"`
- Renamed `websocket_init/1` to `TestServer.HTTP.websocket/1`; it now returns the WebSocket directly instead of `{:ok, websocket}`
- Renamed `websocket_info/2` to `TestServer.HTTP.websocket_send/2`; it now accepts options as its second argument instead of a function
- Replaced `x509_suite/0` with `TestServer.HTTP.cacerts/0`, which returns the CA certificates directly
- Changed `TestServer.HTTP.start/1` to return `{:error, reason}` instead of raising

### Added

- Added SSH support with `TestServer.SSH`
- Added TCP support with `TestServer.TCP`
- Added UDP support with `TestServer.UDP`

### Changed

- Made path argument optional for `TestServer.HTTP.handle/3` and `TestServer.HTTP.websocket/3`
- Instance crashes now propagate to the test process instead of being silently ignored

### Fixed

- Fixed bug where `:match` functions that raised errors always matched in `TestServer.HTTP.handle/3` and `TestServer.HTTP.websocket_handle/2`
- Fixed UTF-8 response body handling for `TestServer.HTTP.Server.Httpd`
- Fixed UTF-8 header and request body handling for `TestServer.HTTP.Server.Httpd`
- Fixed invalid host header port parsing in `TestServer.HTTP.Server.Httpd`
- Fixed bracketed IPv6 host header parsing in `TestServer.HTTP.Server.Httpd`
- Fixed query string parsing with extra `?` segments in `TestServer.HTTP.Server.Httpd`
- Fixed `Bandit` server adapter timeout when discarding an updated conn

## v0.1

The changelog for v0.1 releases can be found in
[the v0.1.22 release](https://github.com/danschultzer/test_server/blob/v0.1.22/CHANGELOG.md).
