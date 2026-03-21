defmodule TestServer.SMTP do
  @external_resource "lib/test_server/smtp/README.md"
  @moduledoc "lib/test_server/smtp/README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias TestServer.SMTP.Instance

  @type handle_response ::
          {:ok, term()}
          | {:ok, binary(), term()}
          | {:error, term()}
          | {:error, binary(), term()}

  @doc """
  Start a test server SMTP instance.

  The instance will be terminated when the test case finishes.

  ## Options

    * `:port`        - integer port number, defaults to random available port;
    * `:hostname`    - server hostname, defaults to `"localhost"`;
    * `:tls`         - set to `true` to enable STARTTLS support with auto-generated
      self-signed certificates;
    * `:credentials` - list of `{username, password}` tuples. When set, the server
      advertises AUTH PLAIN LOGIN and requires authentication;

  ## Examples

      {:ok, instance} = TestServer.SMTP.start(port: 2525)

      {:ok, instance} = TestServer.SMTP.start(tls: true)

      {:ok, instance} = TestServer.SMTP.start(credentials: [{"user", "pass"}])
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(options \\ []) do
    TestServer.start_instance(__MODULE__, options, &verify!/1)
  end

  @doc """
  Shuts down the current test server SMTP instance.
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: stop(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Shuts down a test server SMTP instance.
  """
  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(instance) do
    TestServer.stop_instance(__MODULE__, instance)
  end

  @doc """
  Returns the address of the current test server SMTP instance.

  ## Examples

      TestServer.SMTP.start()
      {"localhost", port} = TestServer.SMTP.address()
  """
  @spec address() :: {binary(), non_neg_integer()}
  def address, do: address(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Returns the address of a test server SMTP instance.
  """
  @spec address(pid()) :: {binary(), non_neg_integer()}
  def address(instance) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    options = Instance.get_options(instance)

    {"localhost", Keyword.fetch!(options, :port)}
  end

  @doc """
  Returns the port of the current test server SMTP instance.
  """
  @spec port() :: non_neg_integer()
  def port, do: port(TestServer.fetch_instance!(__MODULE__))

  @doc """
  Returns the port of a test server SMTP instance.
  """
  @spec port(pid()) :: non_neg_integer()
  def port(instance) do
    {"localhost", port} = address(instance)
    port
  end

  @doc """
  Adds a handler to the SMTP test server instance.

  Handlers are matched FIFO (first in, first out). When an email is received,
  the first non-suspended matching handler is invoked and then suspended.

  Any emails not matched by a handler, or any handlers not consumed by an email,
  will raise an error in the test case.

  ## Options

    * `:to`    - a function/2 `fn email, state -> response end` called when
      the handler matches. Defaults to accepting the email with `{:ok, state}`;
    * `:match` - a function/2 `fn email, state -> boolean end` that receives
      the email and state and returns a boolean. Defaults to matching any email;

  ## Response format

    * `{:ok, state}` — accept the email, responds with "250 2.0.0 Ok"
    * `{:ok, "250 Custom message", state}` — accept with custom response
    * `{:error, state}` — reject the email, responds with "550 5.0.0 Rejected"
    * `{:error, "550 Custom error", state}` — reject with custom response

  ## Examples

      {:ok, instance} = TestServer.SMTP.start()

      # Accept any email (default handler)
      TestServer.SMTP.add(instance)

      # Match on sender
      TestServer.SMTP.add(instance,
        match: fn email, _state -> email.mail_from == "sender@example.com" end,
        to: fn email, state -> {:ok, state} end
      )

      # Reject email
      TestServer.SMTP.add(instance,
        to: fn _email, state -> {:error, "550 5.1.1 User unknown", state} end
      )
  """
  @spec add(pid(), keyword()) :: :ok
  def add(instance \\ TestServer.fetch_instance!(__MODULE__), options \\ [])

  def add(instance, options) when is_pid(instance) and is_list(options) do
    TestServer.ensure_instance_alive!(__MODULE__, instance)

    [_register_entry, _first_module_entry | stacktrace] =
      TestServer.get_pruned_stacktrace(__MODULE__)

    {:ok, _handler} = Instance.register(instance, {options, stacktrace})

    :ok
  end

  def add(options, []) when is_list(options) do
    instance = TestServer.fetch_instance!(__MODULE__)
    add(instance, options)
  end

  defp verify!(instance) do
    instance
    |> Instance.handlers()
    |> Enum.reject(& &1.suspended)
    |> case do
      [] ->
        :ok

      active_handlers ->
        raise """
        #{TestServer.format_instance(__MODULE__, instance)} did not receive expected emails:

        #{Instance.format_handlers(active_handlers)}
        """
    end
  end
end
