defmodule Babel.GRPC.Streamer do
  use GenServer
  require Logger

  @name __MODULE__
  @default_commitment "confirmed"

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def register_slot(pid, min_slot) when is_pid(pid) do
    GenServer.call(@name, {:register_slot, pid, min_slot})
  end

  def register_transactions(pid, opts) when is_pid(pid) and is_map(opts) do
    GenServer.call(@name, {:register_tx, pid, opts})
  end

  def unregister(ref) do
    GenServer.cast(@name, {:unregister, ref})
  end

  def slot_update(slot, metrics) do
    GenServer.cast(@name, {:slot_update, slot, metrics})
  end

  ## Server callbacks

  @impl true
  def init(_) do
    state = %{
      slots: %{},
      transactions: %{},
      poll_timer: nil,
      poll_interval: poll_interval()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register_slot, pid, min_slot}, _from, state) do
    ref = make_ref()
    monitor = Process.monitor(pid)
    slots = Map.put(state.slots, ref, %{pid: pid, monitor: monitor, min_slot: min_slot})

    {:reply, {:ok, ref}, %{state | slots: slots}}
  end

  def handle_call({:register_tx, pid, opts}, _from, state) do
    with {:ok, address} <- fetch_required(opts, :address) do
      ref = make_ref()
      monitor = Process.monitor(pid)
      tx = %{
        pid: pid,
        monitor: monitor,
        address: address,
        commitment: Map.get(opts, :commitment, @default_commitment),
        limit: Map.get(opts, :limit, 20),
        last_signature: nil
      }

      transactions = Map.put(state.transactions, ref, tx)
      state = schedule_poll(%{state | transactions: transactions})

      {:reply, {:ok, ref}, state}
    else
      {:error, reason} ->
        Logger.warn("[GRPC] Rejecting transaction subscription: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:unregister, ref}, state) do
    state
    |> deregister_slot(ref)
    |> deregister_tx(ref)
    |> reschedule_poll()
    |> noreply()
  end

  def handle_cast({:slot_update, slot, metrics}, state) do
    Enum.each(state.slots, fn {ref, info} ->
      if is_nil(info.min_slot) or slot >= info.min_slot do
        send(info.pid, {:slot_update, ref, slot_payload(slot, metrics)})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:poll_transactions, state) do
    state =
      Enum.reduce(state.transactions, state, fn {ref, info}, acc_state ->
        case fetch_signatures(info) do
          {:ok, {updates, last_signature}} ->
            Enum.each(updates, fn payload ->
              send(info.pid, {:tx_update, ref, payload})
            end)

            put_in(acc_state.transactions[ref].last_signature, last_signature)

          {:error, reason} ->
            Logger.warn("[GRPC] Transaction polling failed: #{inspect(reason)}")
            send(info.pid, {:tx_error, ref, reason})
            acc_state
        end
      end)

    {:noreply, reschedule_poll(state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state
    |> remove_by_monitor(monitor)
    |> noreply()
  end

  ## Helpers

  defp noreply(state), do: {:noreply, state}

  defp fetch_required(opts, key) do
    case Map.get(opts, key) do
      nil -> {:error, "missing #{key}"}
      value -> {:ok, value}
    end
  end

  defp schedule_poll(state) do
    if state.poll_timer == nil and map_size(state.transactions) > 0 do
      %{state | poll_timer: Process.send_after(self(), :poll_transactions, 0)}
    else
      state
    end
  end

  defp reschedule_poll(%{transactions: transactions} = state) do
    if map_size(transactions) == 0 do
      cancel_timer(state.poll_timer)
      %{state | poll_timer: nil}
    else
      timer = Process.send_after(self(), :poll_transactions, state.poll_interval)
      %{state | poll_timer: timer}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)

  defp deregister_slot(state, ref) do
    case Map.pop(state.slots, ref) do
      {nil, _} -> state
      {%{monitor: monitor}, slots} ->
        Process.demonitor(monitor, [:flush])
        %{state | slots: slots}
    end
  end

  defp deregister_tx(state, ref) do
    case Map.pop(state.transactions, ref) do
      {nil, _} -> state
      {%{monitor: monitor}, transactions} ->
        Process.demonitor(monitor, [:flush])
        %{state | transactions: transactions}
    end
  end

  defp remove_by_monitor(state, monitor) do
    state
    |> remove_from(:slots, monitor)
    |> remove_from(:transactions, monitor)
    |> reschedule_poll()
  end

  defp remove_from(state, key, monitor) do
    {removed, kept} =
      state[key]
      |> Enum.split_with(fn {_ref, info} -> info.monitor == monitor end)

    Enum.each(removed, fn {_ref, info} ->
      Process.demonitor(info.monitor, [:flush])
    end)

    Map.put(state, key, Map.new(kept))
  end

  defp slot_payload(slot, metrics) do
    %{
      slot: slot,
      tps: Map.get(metrics, :tps, 0.0),
      block_time: Map.get(metrics, :block_time, 0.0),
      timestamp: System.system_time(:second)
    }
  end

  defp fetch_signatures(info) do
    params =
      %{"limit" => info.limit}
      |> maybe_put_commitment(info.commitment)

    case Babel.RPC.Client.get_signatures_for_address(info.address, params) do
      {:ok, list} when is_list(list) ->
        extract_new_signatures(list, info.last_signature, info.address)

      other ->
        other
    end
  end

  defp maybe_put_commitment(params, nil), do: params
  defp maybe_put_commitment(params, commitment), do: Map.put(params, "commitment", commitment)

  defp extract_new_signatures([], last_signature, _address), do: {:ok, {[], last_signature}}

  defp extract_new_signatures(signatures, last_signature, address) do
    {new_items, updated_last} =
      signatures
      |> Enum.reduce_while({[], last_signature}, fn entry, {acc, last} ->
        signature = entry["signature"]

        cond do
          is_nil(signature) ->
            {:cont, {acc, last}}

          last == signature ->
            {:halt, {acc, last}}

          true ->
            payload = build_tx_payload(entry, address)
            {:cont, {[payload | acc], signature}}
        end
      end)

    {:ok, {Enum.reverse(new_items), updated_last}}
  end

  defp build_tx_payload(entry, address) do
    %{
      signature: entry["signature"],
      slot: entry["slot"],
      err: entry["err"],
      address: address,
      block_time: entry["blockTime"]
    }
  end

  defp poll_interval do
    System.get_env("GRPC_TX_POLL_MS", "750")
    |> String.to_integer()
  rescue
    _ -> 750
  end
end
