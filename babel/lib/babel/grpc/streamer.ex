defmodule Babel.GRPC.Streamer do
  use GenServer
  require Logger

  alias Babel.RPC.Client

  @name __MODULE__
  @default_commitment "confirmed"

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def register_slot(pid, min_slot, meta \\ %{}) when is_pid(pid) do
    GenServer.call(@name, {:register_slot, pid, min_slot, meta})
  end

  def register_transactions(pid, opts, meta \\ %{}) when is_pid(pid) and is_map(opts) do
    GenServer.call(@name, {:register_tx, pid, opts, meta})
  end

  def register_account(pid, opts, meta \\ %{}) when is_pid(pid) and is_map(opts) do
    GenServer.call(@name, {:register_account, pid, opts, meta})
  end

  def register_program(pid, opts, meta \\ %{}) when is_pid(pid) and is_map(opts) do
    GenServer.call(@name, {:register_program, pid, opts, meta})
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
      slot_history: [],
      slot_history_size: slot_history_size(),
      transactions: %{},
      tx_history: %{},
      tx_history_size: tx_history_size(),
      accounts: %{},
      account_timer: nil,
      account_poll_interval: account_poll_interval(),
      programs: %{},
      program_timer: nil,
      program_poll_interval: program_poll_interval(),
      poll_timer: nil,
      poll_interval: poll_interval(),
      limits: load_limits()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register_slot, pid, min_slot, meta}, _from, state) do
    key = key_from_meta(meta)

    case check_capacity(state, key) do
      :ok ->
        ref = make_ref()
        monitor = Process.monitor(pid)

        case deliver_slot_history(pid, ref, state.slot_history, state.limits.max_pending_messages) do
          :ok ->
            slots = Map.put(state.slots, ref, %{pid: pid, monitor: monitor, min_slot: min_slot, key: key})
            {:reply, {:ok, ref}, %{state | slots: slots}}

          :drop ->
            Process.demonitor(monitor, [:flush])
            {:reply, {:error, {:backpressure, :slots}}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:register_tx, pid, opts, meta}, _from, state) do
    key = key_from_meta(meta)

    with {:ok, address} <- fetch_required(opts, :address) do
      case check_capacity(state, key) do
        :ok ->
          ref = make_ref()
          monitor = Process.monitor(pid)

          tx = %{
            pid: pid,
            monitor: monitor,
            address: address,
            commitment: Map.get(opts, :commitment, @default_commitment),
            limit: Map.get(opts, :limit, 20),
            last_signature: nil,
            key: key
          }

          history = Map.get(state.tx_history, address, [])

          case deliver_transaction_history(pid, ref, history, state.limits.max_pending_messages) do
            :ok ->
              transactions = Map.put(state.transactions, ref, tx)
              state = %{state | transactions: transactions} |> schedule_tx_poll()
              {:reply, {:ok, ref}, state}

            :drop ->
              Process.demonitor(monitor, [:flush])
              {:reply, {:error, {:backpressure, :transactions}}, state}
          end

        {:error, _} = error ->
          {:reply, error, state}
      end
    else
      {:error, reason} ->
        Logger.warn("[GRPC] Rejecting transaction subscription: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_account, pid, opts, meta}, _from, state) do
    key = key_from_meta(meta)

    with {:ok, address} <- fetch_required(opts, :address),
         commitment <- Map.get(opts, :commitment, @default_commitment),
         :ok <- check_capacity(state, key),
         {:ok, payload, hash} <- fetch_account_state(address, commitment) do
      ref = make_ref()
      monitor = Process.monitor(pid)
      snapshot_payload = Map.put(payload, :snapshot, true)

      case deliver_account_payload(pid, ref, snapshot_payload, state.limits.max_pending_messages) do
        :ok ->
          info = %{
            pid: pid,
            monitor: monitor,
            address: address,
            commitment: commitment,
            key: key,
            last_hash: hash,
            last_slot: payload.slot,
            snapshot_sent?: true
          }

          accounts = Map.put(state.accounts, ref, info)
          state = %{state | accounts: accounts} |> schedule_account_poll()
          {:reply, {:ok, ref}, state}

        :drop ->
          Process.demonitor(monitor, [:flush])
          {:reply, {:error, {:backpressure, :accounts}}, state}
      end
    else
      {:error, reason} ->
        Logger.warn("[GRPC] Rejecting account subscription: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_program, pid, opts, meta}, _from, state) do
    key = key_from_meta(meta)

    with {:ok, program_id} <- fetch_required(opts, :program_id),
         commitment <- Map.get(opts, :commitment, @default_commitment),
         filters <- Map.get(opts, :filters, []),
         :ok <- check_capacity(state, key),
         {:ok, slot, account_map, updates} <- fetch_program_state(program_id, commitment, filters, %{}) do
      ref = make_ref()
      monitor = Process.monitor(pid)

      case deliver_program_updates(pid, ref, updates, true, state.limits.max_pending_messages) do
        :ok ->
          info = %{
            pid: pid,
            monitor: monitor,
            program_id: program_id,
            commitment: commitment,
            filters: filters,
            key: key,
            accounts: account_map,
            last_slot: slot,
            snapshot_sent?: true
          }

          programs = Map.put(state.programs, ref, info)
          state = %{state | programs: programs} |> schedule_program_poll()
          {:reply, {:ok, ref}, state}

        :drop ->
          Process.demonitor(monitor, [:flush])
          {:reply, {:error, {:backpressure, :programs}}, state}
      end
    else
      {:error, reason} ->
        Logger.warn("[GRPC] Rejecting program subscription: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:unregister, ref}, state) do
    state
    |> deregister_slot(ref)
    |> deregister_tx(ref)
    |> deregister_account(ref)
    |> deregister_program(ref)
    |> reschedule_all()
    |> noreply()
  end

  def handle_cast({:slot_update, slot, metrics}, state) do
    payload = slot_payload(slot, metrics)
    slot_history = update_slot_history(state.slot_history, payload, state.slot_history_size)

    slots =
      Enum.reduce(state.slots, %{}, fn {ref, info}, acc ->
        cond do
          not eligible_slot?(info.min_slot, slot) ->
            Map.put(acc, ref, info)

          allow_send?(info.pid, state.limits.max_pending_messages) ->
            send(info.pid, {:slot_update, ref, Map.put(payload, :snapshot, false)})
            Map.put(acc, ref, info)

          true ->
            Logger.warn("[GRPC] Dropping slot subscriber due to backpressure (key=#{info.key})")
            send(info.pid, {:overload, ref, :slots})
            Process.demonitor(info.monitor, [:flush])
            acc
        end
      end)

    {:noreply, %{state | slots: slots, slot_history: slot_history}}
  end

  @impl true
  def handle_info(:poll_transactions, state) do
    {transactions, tx_history} =
      Enum.reduce(state.transactions, {%{}, state.tx_history}, fn {ref, info}, {acc, history} ->
        case fetch_signatures(info) do
          {:ok, {updates, last_signature}} ->
            info = %{info | last_signature: last_signature}
            updates = Enum.map(updates, &Map.put(&1, :snapshot, false))

            case deliver_transaction_updates(ref, info, updates, state.limits.max_pending_messages) do
              {:keep, updated_info} ->
                history = update_tx_history(history, info.address, updates, state.tx_history_size)
                {Map.put(acc, ref, updated_info), history}

              :drop ->
                {acc, history}
            end

          {:error, reason} ->
            Logger.warn("[GRPC] Transaction polling failed: #{inspect(reason)}")
            send(info.pid, {:tx_error, ref, reason})
            {acc, history}
        end
      end)

    state = %{state | transactions: transactions, tx_history: tx_history}
    {:noreply, reschedule_tx_poll(state)}
  end

  def handle_info(:poll_accounts, state) do
    accounts =
      Enum.reduce(state.accounts, %{}, fn {ref, info}, acc ->
        case fetch_account_state(info.address, info.commitment) do
          {:ok, payload, hash} ->
            cond do
              hash == info.last_hash and info.snapshot_sent? ->
                Map.put(acc, ref, info)

              allow_send?(info.pid, state.limits.max_pending_messages) ->
                snapshot = not info.snapshot_sent?
                payload = Map.put(payload, :snapshot, snapshot)
                send(info.pid, {:account_update, ref, payload})

                updated_info = %{info | last_hash: hash, last_slot: payload.slot, snapshot_sent?: true}
                Map.put(acc, ref, updated_info)

              true ->
                Logger.warn("[GRPC] Dropping account subscriber due to backpressure (key=#{info.key})")
                send(info.pid, {:overload, ref, :accounts})
                Process.demonitor(info.monitor, [:flush])
                acc
            end

          {:error, reason} ->
            Logger.warn("[GRPC] Account polling failed: #{inspect(reason)}")
            send(info.pid, {:account_error, ref, reason})
            Map.put(acc, ref, info)
        end
      end)

    state = %{state | accounts: accounts}
    {:noreply, reschedule_account_poll(state)}
  end

  def handle_info(:poll_programs, state) do
    programs =
      Enum.reduce(state.programs, %{}, fn {ref, info}, acc ->
        case fetch_program_state(info.program_id, info.commitment, info.filters, info.accounts || %{}) do
          {:ok, slot, account_map, updates} ->
            snapshot_flag = not info.snapshot_sent?

            case deliver_program_updates(info.pid, ref, updates, snapshot_flag, state.limits.max_pending_messages) do
              :ok ->
                updated_info = %{
                  info
                  | accounts: account_map,
                    last_slot: slot,
                    snapshot_sent?: true
                }

                Map.put(acc, ref, updated_info)

              :drop ->
                Process.demonitor(info.monitor, [:flush])
                acc
            end

          {:error, reason} ->
            Logger.warn("[GRPC] Program polling failed: #{inspect(reason)}")
            Map.put(acc, ref, info)
        end
      end)

    state = %{state | programs: programs}
    {:noreply, reschedule_program_poll(state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state
    |> remove_by_monitor(monitor)
    |> reschedule_all()
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

  defp schedule_tx_poll(state) do
    if state.poll_timer == nil and map_size(state.transactions) > 0 do
      %{state | poll_timer: Process.send_after(self(), :poll_transactions, 0)}
    else
      state
    end
  end

  defp reschedule_tx_poll(%{transactions: transactions} = state) do
    if map_size(transactions) == 0 do
      cancel_timer(state.poll_timer)
      %{state | poll_timer: nil}
    else
      timer = Process.send_after(self(), :poll_transactions, state.poll_interval)
      %{state | poll_timer: timer}
    end
  end

  defp schedule_account_poll(state) do
    if state.account_timer == nil and map_size(state.accounts) > 0 do
      %{state | account_timer: Process.send_after(self(), :poll_accounts, 0)}
    else
      state
    end
  end

  defp reschedule_account_poll(%{accounts: accounts} = state) do
    if map_size(accounts) == 0 do
      cancel_timer(state.account_timer)
      %{state | account_timer: nil}
    else
      timer = Process.send_after(self(), :poll_accounts, state.account_poll_interval)
      %{state | account_timer: timer}
    end
  end

  defp schedule_program_poll(state) do
    if state.program_timer == nil and map_size(state.programs) > 0 do
      %{state | program_timer: Process.send_after(self(), :poll_programs, 0)}
    else
      state
    end
  end

  defp reschedule_program_poll(%{programs: programs} = state) do
    if map_size(programs) == 0 do
      cancel_timer(state.program_timer)
      %{state | program_timer: nil}
    else
      timer = Process.send_after(self(), :poll_programs, state.program_poll_interval)
      %{state | program_timer: timer}
    end
  end

  defp reschedule_all(state) do
    state
    |> reschedule_tx_poll()
    |> reschedule_account_poll()
    |> reschedule_program_poll()
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

  defp deregister_account(state, ref) do
    case Map.pop(state.accounts, ref) do
      {nil, _} -> state
      {%{monitor: monitor}, accounts} ->
        Process.demonitor(monitor, [:flush])
        %{state | accounts: accounts}
    end
  end

  defp deregister_program(state, ref) do
    case Map.pop(state.programs, ref) do
      {nil, _} -> state
      {%{monitor: monitor}, programs} ->
        Process.demonitor(monitor, [:flush])
        %{state | programs: programs}
    end
  end

  defp remove_by_monitor(state, monitor) do
    state
    |> remove_from(:slots, monitor)
    |> remove_from(:transactions, monitor)
    |> remove_from(:accounts, monitor)
    |> remove_from(:programs, monitor)
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

  defp deliver_slot_history(_pid, _ref, [], _limit), do: :ok

  defp deliver_slot_history(pid, ref, history, limit) do
    history
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn payload, _ ->
      if allow_send?(pid, limit) do
        send(pid, {:slot_update, ref, Map.put(payload, :snapshot, true)})
        {:cont, :ok}
      else
        send(pid, {:overload, ref, :slots})
        {:halt, :drop}
      end
    end)
  end

  defp deliver_transaction_history(_pid, _ref, [], _limit), do: :ok

  defp deliver_transaction_history(pid, ref, history, limit) do
    history
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn payload, _ ->
      if allow_send?(pid, limit) do
        send(pid, {:tx_update, ref, Map.put(payload, :snapshot, true)})
        {:cont, :ok}
      else
        send(pid, {:overload, ref, :transactions})
        {:halt, :drop}
      end
    end)
  end

  defp deliver_account_payload(pid, ref, payload, limit) do
    if allow_send?(pid, limit) do
      send(pid, {:account_update, ref, payload})
      :ok
    else
      send(pid, {:overload, ref, :accounts})
      :drop
    end
  end

  defp deliver_program_updates(_pid, _ref, [], _snapshot, _limit), do: :ok

  defp deliver_program_updates(pid, ref, updates, snapshot_flag, limit) do
    Enum.reduce_while(updates, :ok, fn payload, _ ->
      payload = Map.put(payload, :snapshot, Map.get(payload, :snapshot, snapshot_flag))

      if allow_send?(pid, limit) do
        send(pid, {:program_update, ref, payload})
        {:cont, :ok}
      else
        send(pid, {:overload, ref, :programs})
        {:halt, :drop}
      end
    end)
  end

  defp deliver_transaction_updates(ref, info, updates, limit) do
    if updates == [] do
      {:keep, info}
    else
      if allow_send?(info.pid, limit) do
        Enum.each(updates, fn payload ->
          send(info.pid, {:tx_update, ref, payload})
        end)

        {:keep, info}
      else
        Logger.warn("[GRPC] Dropping transaction subscriber due to backpressure (key=#{info.key})")
        send(info.pid, {:overload, ref, :transactions})
        Process.demonitor(info.monitor, [:flush])
        :drop
      end
    end
  end

  defp slot_payload(slot, metrics) do
    %{
      slot: slot,
      tps: Map.get(metrics, :tps, 0.0),
      block_time: Map.get(metrics, :block_time, 0.0),
      timestamp: System.system_time(:second)
    }
  end

  defp update_slot_history(history, payload, size) do
    [payload | history]
    |> Enum.take(size)
  end

  defp fetch_signatures(info) do
    params =
      %{"limit" => info.limit}
      |> maybe_put_commitment(info.commitment)

    case Client.get_signatures_for_address(info.address, params) do
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

  defp update_tx_history(history, _address, [], _size), do: history

  defp update_tx_history(history, address, updates, size) do
    existing = Map.get(history, address, [])
    combined = Enum.take(Enum.reverse(updates) ++ existing, size)
    Map.put(history, address, combined)
  end

  defp fetch_account_state(address, commitment) do
    params = %{"encoding" => "base64", "commitment" => commitment, "withContext" => true}

    case Client.get_account_info(address, params) do
      {:ok, %{"value" => nil, "context" => %{"slot" => slot}}} ->
        payload = %{
          address: address,
          slot: slot,
          lamports: 0,
          owner: "",
          data: <<>>,
          encoding: "base64",
          executable: false,
          rent_epoch: 0,
          status: :ACCOUNT_STATUS_NOT_FOUND
        }

        {:ok, payload, {:not_found, slot}}

      {:ok, %{"value" => value, "context" => %{"slot" => slot}}} ->
        {data, encoding} = decode_account_data(value["data"])

        payload = %{
          address: address,
          slot: slot,
          lamports: value["lamports"] || 0,
          owner: value["owner"] || "",
          data: data,
          encoding: encoding,
          executable: value["executable"] || false,
          rent_epoch: value["rentEpoch"] || 0,
          status: :ACCOUNT_STATUS_EXISTS
        }

        hash = :erlang.phash2({payload.lamports, payload.owner, payload.data, payload.executable, payload.rent_epoch})
        {:ok, payload, hash}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp decode_account_data([data, encoding]) when is_binary(data) and is_binary(encoding) do
    case String.downcase(encoding) do
      "base64" ->
        case Base.decode64(data) do
          {:ok, decoded} -> {decoded, "base64"}
          :error -> {<<>>, "base64"}
        end

      _ ->
        {<<>>, encoding}
    end
  end

  defp decode_account_data(_), do: {<<>>, "base64"}

  defp fetch_program_state(program_id, commitment, filters, prev_accounts) do
    params =
      %{"encoding" => "base64", "withContext" => true, "commitment" => commitment}
      |> maybe_put_filters(filters)

    case Client.get_program_accounts(program_id, params) do
      {:ok, %{"context" => %{"slot" => slot}, "value" => accounts}} when is_list(accounts) ->
        new_map = build_program_account_map(accounts, program_id, slot)
        updates = diff_program_accounts(prev_accounts, new_map, program_id, slot)
        {:ok, slot, new_map, updates}

      {:ok, list} when is_list(list) ->
        new_map = build_program_account_map(list, program_id, 0)
        updates = diff_program_accounts(prev_accounts, new_map, program_id, 0)
        {:ok, 0, new_map, updates}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp maybe_put_filters(params, []), do: params

  defp maybe_put_filters(params, filters) do
    rpc_filters =
      filters
      |> Enum.flat_map(fn filter ->
        [
          build_memcmp_filter(filter),
          build_datasize_filter(filter)
        ]
      end)
      |> Enum.reject(&is_nil/1)

    Map.put(params, "filters", rpc_filters)
  end

  defp build_memcmp_filter(filter) do
    with offset when is_integer(offset) <- filter[:memcmp_offset],
         bytes when is_binary(bytes) and bytes != "" <- filter[:memcmp_bytes] do
      %{
        "memcmp" => %{
          "offset" => offset,
          "bytes" => bytes
        }
      }
    else
      _ -> nil
    end
  end

  defp build_datasize_filter(filter) do
    case filter[:data_size] do
      nil -> nil
      size -> %{"dataSize" => size}
    end
  end

  defp build_program_account_map(accounts, program_id, _slot) do
    accounts
    |> Enum.reduce(%{}, fn entry, acc ->
      account = program_account_data(entry)
      hash = :erlang.phash2({account.lamports, account.owner, account.data, account.rent_epoch})
      Map.put(acc, account.address, %{hash: hash, account: account})
    end)
  end

  defp diff_program_accounts(prev_map, new_map, program_id, slot) do
    updated =
      Enum.reduce(new_map, [], fn {address, %{hash: hash, account: account}}, acc ->
        case Map.get(prev_map, address) do
          nil ->
            [program_update_payload(program_id, account, slot, :PROGRAM_STATUS_UPDATED) | acc]

          %{hash: prev_hash} when prev_hash != hash ->
            [program_update_payload(program_id, account, slot, :PROGRAM_STATUS_UPDATED) | acc]

          _ ->
            acc
        end
      end)

    removed =
      prev_map
      |> Enum.reject(fn {address, _} -> Map.has_key?(new_map, address) end)
      |> Enum.map(fn {_address, %{account: account}} ->
        program_update_payload(program_id, account, slot, :PROGRAM_STATUS_DELETED)
      end)

    Enum.reverse(updated) ++ removed
  end

  defp program_account_data(%{"pubkey" => pubkey, "account" => account}) do
    {data, encoding} = decode_account_data(account["data"])

    %{
      address: pubkey,
      lamports: account["lamports"] || 0,
      owner: account["owner"] || "",
      data: data,
      encoding: encoding,
      executable: account["executable"] || false,
      rent_epoch: account["rentEpoch"] || 0
    }
  end

  defp program_account_data(_), do: %{address: "", lamports: 0, owner: "", data: <<>>, encoding: "base64", executable: false, rent_epoch: 0}

  defp program_update_payload(program_id, account, slot, status) do
    %{
      program_id: program_id,
      status: status,
      account: account,
      slot: slot
    }
  end

  defp eligible_slot?(nil, _slot), do: true
  defp eligible_slot?(min_slot, slot) when is_integer(min_slot), do: slot >= min_slot

  defp allow_send?(_pid, limit) when limit <= 0, do: true

  defp allow_send?(pid, limit) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when len <= limit -> true
      {:message_queue_len, _len} -> false
      _ -> false
    end
  end

  defp check_capacity(state, key) do
    limits = state.limits
    total =
      map_size(state.slots) +
        map_size(state.transactions) +
        map_size(state.accounts) +
        map_size(state.programs)

    cond do
      limits.max_streams > 0 and total >= limits.max_streams ->
        {:error, :over_capacity}

      limits.max_streams_per_key > 0 and streams_for_key(state, key) >= limits.max_streams_per_key ->
        {:error, {:key_capacity, key}}

      true ->
        :ok
    end
  end

  defp streams_for_key(state, key) do
    Enum.count(state.slots, fn {_ref, info} -> info.key == key end) +
      Enum.count(state.transactions, fn {_ref, info} -> info.key == key end) +
      Enum.count(state.accounts, fn {_ref, info} -> info.key == key end) +
      Enum.count(state.programs, fn {_ref, info} -> info.key == key end)
  end

  defp key_from_meta(meta) when is_map(meta) do
    meta
    |> Map.get(:key)
    |> normalize_key()
    |> case do
      nil -> "anonymous"
      key -> key
    end
  end

  defp key_from_meta(_), do: "anonymous"

  defp normalize_key(nil), do: nil

  defp normalize_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_key(_), do: nil

  defp load_limits do
    %{
      max_streams: env_int("GRPC_MAX_STREAMS", 200),
      max_streams_per_key: env_int("GRPC_MAX_STREAMS_PER_KEY", 50),
      max_pending_messages: env_int("GRPC_MAX_PENDING_MESSAGES", 500)
    }
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end
    end
  end

  defp poll_interval do
    System.get_env("GRPC_TX_POLL_MS", "750")
    |> String.to_integer()
  rescue
    _ -> 750
  end

  defp account_poll_interval do
    env_int("GRPC_ACCOUNT_POLL_MS", 1500)
  end

  defp program_poll_interval do
    env_int("GRPC_PROGRAM_POLL_MS", 2500)
  end

  defp slot_history_size do
    env_int("GRPC_SLOT_HISTORY_SIZE", 64)
  end

  defp tx_history_size do
    env_int("GRPC_TX_HISTORY_SIZE", 64)
  end
end
