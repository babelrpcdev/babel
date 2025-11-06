defmodule Babel.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Babel RPC Manager")

    children = [
      # Telemetry supervisor
      Babel.Telemetry,
      
      # RPC client pool
      {Babel.RPC.Client, []},
      
      # WebSocket subscriber for real-time events
      {Babel.RPC.Subscriber, []},
      
      # Health monitor
      {Babel.Monitor, []},
      
      # Metrics exporter
      {Babel.Metrics, []},
      
      # HTTP API
      {Plug.Cowboy, scheme: :http, plug: Babel.API.Router, options: [port: 4000]}
    ]

    opts = [strategy: :one_for_one, name: Babel.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

