defmodule Babel.RPC.Subscriber do
  use GenServer
  require Logger

  @ws_endpoint System.get_env("WS_ENDPOINT", "ws://solana-rpc:8900")

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("Initializing WebSocket Subscriber: #{@ws_endpoint}")
    send(self(), :connect)
    {:ok, %{ws: nil, subscriptions: %{}, reconnect_timer: nil}}
  end

  # Subscribe to account changes
  def subscribe_account(pubkey, callback) do
    GenServer.call(__MODULE__, {:subscribe_account, pubkey, callback})
  end

  # Subscribe to program accounts
  def subscribe_program(program_id, filters, callback) do
    GenServer.call(__MODULE__, {:subscribe_program, program_id, filters, callback})
  end

  # Subscribe to slot updates
  def subscribe_slot(callback) do
    GenServer.call(__MODULE__, {:subscribe_slot, callback})
  end

  # Subscribe to logs
  def subscribe_logs(filter, callback) do
    GenServer.call(__MODULE__, {:subscribe_logs, filter, callback})
  end

  @impl true
  def handle_info(:connect, state) do
    case WebSockex.start_link(@ws_endpoint, __MODULE__.WsHandler, self()) do
      {:ok, ws} ->
        Logger.info("WebSocket connected")
        {:noreply, %{state | ws: ws, reconnect_timer: nil}}

      {:error, reason} ->
        Logger.error("WebSocket connection failed: #{inspect(reason)}")
        timer = Process.send_after(self(), :connect, 5_000)
        {:noreply, %{state | reconnect_timer: timer}}
    end
  end

  def handle_info({:ws_message, message}, state) do
    handle_ws_message(message, state)
  end

  def handle_info({:ws_closed, reason}, state) do
    Logger.warn("WebSocket closed: #{inspect(reason)}")
    timer = Process.send_after(self(), :connect, 5_000)
    {:noreply, %{state | ws: nil, reconnect_timer: timer}}
  end

  @impl true
  def handle_call({:subscribe_account, pubkey, callback}, _from, state) do
    # Implementation for account subscription
    {:reply, {:ok, :subscribed}, state}
  end

  def handle_call({:subscribe_program, program_id, _filters, callback}, _from, state) do
    # Implementation for program subscription
    {:reply, {:ok, :subscribed}, state}
  end

  def handle_call({:subscribe_slot, callback}, _from, state) do
    # Implementation for slot subscription
    {:reply, {:ok, :subscribed}, state}
  end

  def handle_call({:subscribe_logs, filter, callback}, _from, state) do
    # Implementation for logs subscription
    {:reply, {:ok, :subscribed}, state}
  end

  defp handle_ws_message(message, state) do
    case Jason.decode(message) do
      {:ok, data} ->
        # Process notification
        Logger.debug("WS message: #{inspect(data)}")
        :telemetry.execute([:babel, :ws, :message], %{count: 1}, %{})

      {:error, reason} ->
        Logger.error("Failed to decode WS message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defmodule WsHandler do
    use WebSockex
    require Logger

    def handle_frame({:text, message}, parent) do
      send(parent, {:ws_message, message})
      {:ok, parent}
    end

    def handle_disconnect(_reason, parent) do
      send(parent, {:ws_closed, :disconnected})
      {:ok, parent}
    end
  end
end

