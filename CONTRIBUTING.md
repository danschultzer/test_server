# Contributing

Thanks for considering contributing to TestServer!

## Test suite

TestServer supports several HTTP server adapter. The adapter is selected via the `HTTP_SERVER` environment variable:

```bash
HTTP_SERVER=Bandit mix test
HTTP_SERVER=Plug.Cowboy mix test
HTTP_SERVER=Httpd mix test
```

CI runs the [full matrix](.github/workflows/ci.yml) across `Bandit`, `Plug.Cowboy`, and `:httpd`.

## Code quality

Elixir formatter, `Credo`, and `:dialyzer` are used:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
```

## Protocol architecture

TestServer consists of different protocols with normally these functions:

* `start(options)` - Starts the instance the server
* `stop(instance)` - Stops the server and the instance
* `handle(instance, options)` - Adds an expectation handler. Takes `:to` and `:match` function option.

If the protocol is bidirectional you would also have:

* `send(instance, options)` - Sends message to the active process and handles the reply the same way as `handle`. Takes `:to` function option.

### Option conventions

- Options should mirror the underlying OTP option names verbatim when it makes sense (e.g. `:ipfamily` or `:no_auth_needed`)
- Options should otherwise use Elixir conventions like snake case (`:listen_options`, `:recv_timeout`).

## Submitting a PR

- Write a focused pull request description and link any related issue
- Update `CHANGELOG.md` under `## Unreleased`
- If behavior changes, add or update tests
- Ensure the full adapter matrix passes locally before pushing