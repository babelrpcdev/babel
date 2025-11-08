defmodule Babel.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Babel RPC Manager")

    grpc_port = grpc_port()

    children = [
      # Telemetry supervisor
      Babel.Telemetry,
      
      # RPC client pool
      {Babel.RPC.Client, []},
      
      # WebSocket subscriber for real-time events
      {Babel.RPC.Subscriber, []},
      
      # gRPC Streamer bridge
      Babel.GRPC.Streamer,

      # Health monitor
      {Babel.Monitor, []},
      
      # Metrics exporter
      {Babel.Metrics, []},
      
      # HTTP API
      {Plug.Cowboy, scheme: :http, plug: Babel.API.Router, options: [port: 4000]},

      # gRPC API
      {GRPC.Server.Supervisor, {Babel.GRPC.Server, grpc_port}}
    ]

    opts = [strategy: :one_for_one, name: Babel.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp grpc_port do
    System.get_env("GRPC_PORT", "50051")
    |> String.to_integer()
  rescue
    _ -> 50051
  end
end

