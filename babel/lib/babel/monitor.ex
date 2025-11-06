defmodule Babel.Monitor do
  use GenServer
  require Logger
  alias Babel.RPC.Client

  @check_interval 10_000  # 10 seconds

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("Starting RPC Monitor")
    schedule_check()
    {:ok, %{
      healthy: false,
      last_slot: 0,
      last_check: nil,
      consecutive_failures: 0,
      metrics: %{
        slot_progression: 0,
        tps: 0,
        block_time: 0
      }
    }}
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @impl true
  def handle_info(:check_health, state) do
    new_state = perform_health_check(state)
    schedule_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  defp perform_health_check(state) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, health} <- Client.get_health(),
         {:ok, slot} <- Client.get_slot(),
         {:ok, performance} <- Client.get_recent_performance_samples(1) do
      
      slot_progression = if state.last_slot > 0, do: slot - state.last_slot, else: 0
      
      metrics = case performance do
        [sample | _] ->
          %{
            slot_progression: slot_progression,
            tps: sample["numTransactions"] / sample["samplePeriodSecs"],
            block_time: sample["samplePeriodSecs"] / sample["numSlots"]
          }
        _ ->
          state.metrics
      end

      check_duration = System.monotonic_time(:millisecond) - start_time

      # Emit telemetry
      :telemetry.execute(
        [:babel, :monitor, :health_check],
        %{
          duration: check_duration,
          slot: slot,
          slot_progression: slot_progression,
          tps: metrics.tps
        },
        %{healthy: true}
      )

      Logger.info("Health check passed - Slot: #{slot}, TPS: #{Float.round(metrics.tps, 2)}")

      %{
        state |
        healthy: true,
        last_slot: slot,
        last_check: DateTime.utc_now(),
        consecutive_failures: 0,
        metrics: metrics
      }

    else
      error ->
        consecutive_failures = state.consecutive_failures + 1
        Logger.error("Health check failed: #{inspect(error)} (#{consecutive_failures} consecutive)")

        :telemetry.execute(
          [:babel, :monitor, :health_check],
          %{duration: 0},
          %{healthy: false, consecutive_failures: consecutive_failures}
        )

        %{
          state |
          healthy: false,
          last_check: DateTime.utc_now(),
          consecutive_failures: consecutive_failures
        }
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_health, @check_interval)
  end
end

