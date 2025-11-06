defmodule Babel.Metrics do
  use GenServer
  require Logger
  require Prometheus.Registry

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("Initializing Metrics Exporter")
    
    # Setup Prometheus metrics
    setup_metrics()
    
    # Attach telemetry handlers
    attach_handlers()
    
    {:ok, %{}}
  end

  defp setup_metrics do
    # RPC Request metrics
    Prometheus.Metric.Counter.declare(
      name: :babel_rpc_requests_total,
      help: "Total number of RPC requests",
      labels: [:method, :status]
    )

    Prometheus.Metric.Histogram.declare(
      name: :babel_rpc_request_duration_microseconds,
      help: "RPC request duration in microseconds",
      labels: [:method],
      buckets: [100, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]
    )

    # WebSocket metrics
    Prometheus.Metric.Counter.declare(
      name: :babel_ws_messages_total,
      help: "Total number of WebSocket messages received",
      labels: []
    )

    # Health metrics
    Prometheus.Metric.Gauge.declare(
      name: :babel_node_healthy,
      help: "Current health status of the node (1 = healthy, 0 = unhealthy)",
      labels: []
    )

    Prometheus.Metric.Gauge.declare(
      name: :babel_node_slot,
      help: "Current slot number",
      labels: []
    )

    Prometheus.Metric.Gauge.declare(
      name: :babel_node_tps,
      help: "Current transactions per second",
      labels: []
    )

    Prometheus.Metric.Gauge.declare(
      name: :babel_node_block_time,
      help: "Average block time in seconds",
      labels: []
    )

    Prometheus.Metric.Counter.declare(
      name: :babel_health_check_failures_total,
      help: "Total number of consecutive health check failures",
      labels: []
    )
  end

  defp attach_handlers do
    # RPC request handler
    :telemetry.attach(
      "babel-rpc-request",
      [:babel, :rpc, :request],
      &handle_rpc_request/4,
      nil
    )

    # WebSocket message handler
    :telemetry.attach(
      "babel-ws-message",
      [:babel, :ws, :message],
      &handle_ws_message/4,
      nil
    )

    # Health check handler
    :telemetry.attach(
      "babel-health-check",
      [:babel, :monitor, :health_check],
      &handle_health_check/4,
      nil
    )
  end

  defp handle_rpc_request(_event, %{duration: duration}, %{method: method, status: status}, _config) do
    Prometheus.Metric.Counter.inc(
      name: :babel_rpc_requests_total,
      labels: [method, status]
    )

    Prometheus.Metric.Histogram.observe(
      name: :babel_rpc_request_duration_microseconds,
      labels: [method],
      value: duration
    )
  end

  defp handle_ws_message(_event, %{count: count}, _metadata, _config) do
    Prometheus.Metric.Counter.inc(
      name: :babel_ws_messages_total,
      value: count
    )
  end

  defp handle_health_check(_event, measurements, metadata, _config) do
    case metadata do
      %{healthy: true} ->
        Prometheus.Metric.Gauge.set(name: :babel_node_healthy, value: 1)
        
        Prometheus.Metric.Gauge.set(
          name: :babel_node_slot,
          value: measurements[:slot] || 0
        )
        
        Prometheus.Metric.Gauge.set(
          name: :babel_node_tps,
          value: measurements[:tps] || 0
        )

      %{healthy: false, consecutive_failures: failures} ->
        Prometheus.Metric.Gauge.set(name: :babel_node_healthy, value: 0)
        Prometheus.Metric.Counter.inc(
          name: :babel_health_check_failures_total,
          value: 1
        )
    end
  end
end

