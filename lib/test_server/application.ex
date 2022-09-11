defmodule TestServer.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      TestServer.InstanceManager,
      {DynamicSupervisor, strategy: :one_for_one, name: TestServer.InstanceSupervisor}
    ]

    opts = [strategy: :one_for_one, name: TestServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
