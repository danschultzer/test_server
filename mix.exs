defmodule TestServer.MixProject do
  use Mix.Project

  @source_url "https://github.com/danschultzer/test_server"
  @version "0.1.18"

  def project do
    [
      app: :test_server,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex
      description: "Mock third-party services in ExUnit",
      package: package(),

      # Docs
      name: "TestServer",
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key],
      mod: {TestServer.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.14"},
      {:x509, "~> 0.6"},

      # Optional web servers
      {:bandit, ">= 1.4.0", optional: true},
      {:plug_cowboy, ">= 2.0.0", optional: true},

      # Development and test
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:ssl_verify_fun, ">= 0.0.0", only: [:test]},
      {:credo, ">= 0.0.0", only: [:dev, :test]},
      {:websockex, "~> 0.4.3", only: [:test]},
      {:finch, ">= 0.0.0", only: [:test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Dan Schultzer"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Sponsor" => "https://github.com/sponsors/danschultzer"
      },
      files: ~w(lib LICENSE mix.exs README.md)
    ]
  end

  defp docs do
    [
      source_ref: "v#{@version}",
      main: "README",
      canonical: "http://hexdocs.pm/test_server",
      source_url: @source_url,
      extras: [
        "README.md": [filename: "README"],
        "CHANGELOG.md": [filename: "CHANGELOG"]
      ],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md"
      ]
    ]
  end
end
