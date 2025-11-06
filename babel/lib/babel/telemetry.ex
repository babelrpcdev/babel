defmodule Babel.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # RPC Metrics
      counter("babel.rpc.request.count",
        tags: [:method, :status],
        description: "Total number of RPC requests"
      ),
      
      distribution("babel.rpc.request.duration",
        unit: {:native, :microsecond},
        tags: [:method],
        description: "RPC request duration",
        reporter_options: [
          buckets: [100, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]
        ]
      ),

      # WebSocket Metrics
      counter("babel.ws.message.count",
        description: "Total WebSocket messages received"
      ),

      # Health Metrics
      last_value("babel.monitor.health_check.slot",
        description: "Current slot number"
      ),
      
      last_value("babel.monitor.health_check.tps",
        description: "Transactions per second"
      ),
      
      last_value("babel.monitor.health_check.slot_progression",
        description: "Slot progression since last check"
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.system_counts.process_count")
    ]
  end

  defp periodic_measurements do
    []
  end
end

