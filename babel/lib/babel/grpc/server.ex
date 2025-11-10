defmodule Babel.GRPC.Stream.SlotRequest do
  use Protobuf, syntax: :proto3

  field :starting_slot, 1, type: :uint64, json_name: "startingSlot"
end

defmodule Babel.GRPC.Stream.SlotUpdate do
  use Protobuf, syntax: :proto3

  field :slot, 1, type: :uint64
  field :tps, 2, type: :double
  field :block_time, 3, type: :double, json_name: "blockTime"
  field :timestamp, 4, type: :uint64
end

defmodule Babel.GRPC.Stream.TransactionRequest do
  use Protobuf, syntax: :proto3

  field :address, 1, type: :string
  field :commitment, 2, type: :string
  field :limit, 3, type: :uint32
end

defmodule Babel.GRPC.Stream.TransactionUpdate do
  use Protobuf, syntax: :proto3

  field :signature, 1, type: :string
  field :address, 2, type: :string
  field :slot, 3, type: :uint64
  field :error, 4, type: :string
  field :block_time, 5, type: :uint64, json_name: "blockTime"
end

defmodule Babel.GRPC.Stream.Service do
  use GRPC.Service, name: "babel.stream.BabelStream"

  rpc :SubscribeSlots, Babel.GRPC.Stream.SlotRequest, stream(Babel.GRPC.Stream.SlotUpdate)
  rpc :SubscribeTransactions, Babel.GRPC.Stream.TransactionRequest, stream(Babel.GRPC.Stream.TransactionUpdate)
end

defmodule Babel.GRPC.Server do
  use GRPC.Server, service: Babel.GRPC.Stream.Service

  require Logger

  alias Babel.GRPC.{Auth, Streamer}
  alias Babel.GRPC.Stream.{SlotUpdate, TransactionUpdate}

  @impl true
  def subscribe_slots(%Babel.GRPC.Stream.SlotRequest{starting_slot: starting_slot}, stream) do
    with {:ok, ctx} <- Auth.authorize(stream.metadata),
         {:ok, ref} <- Streamer.register_slot(self(), starting_slot, ctx) do
      Logger.debug("[GRPC] Slot subscription registered (min_slot=#{starting_slot}, key=#{ctx.key})")
      monitor = Process.monitor(stream.pid)

      try do
        slot_loop(stream, ref, monitor)
      after
        Streamer.unregister(ref)
      end
    else
      {:error, reason} ->
        raise_rpc_error(reason)
    end
  end

  @impl true
  def subscribe_transactions(%Babel.GRPC.Stream.TransactionRequest{} = request, stream) do
    opts = %{
      address: normalize_string(request.address),
      commitment: normalize_string(request.commitment),
      limit: sanitize_limit(request.limit)
    }

    with {:ok, ctx} <- Auth.authorize(stream.metadata),
         {:ok, ref} <- Streamer.register_transactions(self(), opts, ctx) do
      Logger.debug("[GRPC] Transaction subscription registered (address=#{opts.address}, key=#{ctx.key})")
      monitor = Process.monitor(stream.pid)

      try do
        tx_loop(stream, ref, monitor)
      after
        Streamer.unregister(ref)
      end
    else
      {:error, reason} ->
        raise_rpc_error(reason)
    end
  end

  ## Loop handlers

  defp slot_loop(stream, ref, monitor) do
    receive do
      {:slot_update, ^ref, payload} ->
        payload
        |> SlotUpdate.new()
        |> send_reply(stream)

        slot_loop(stream, ref, monitor)

      {:overload, ^ref, scope} ->
        raise_rpc_error({:backpressure, scope})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok

      {:stop, ^ref} ->
        :ok

      {:tx_update, _, _} ->
        slot_loop(stream, ref, monitor)
    after
      30_000 ->
        slot_loop(stream, ref, monitor)
    end
  end

  defp tx_loop(stream, ref, monitor) do
    receive do
      {:tx_update, ^ref, payload} ->
        payload
        |> transaction_update_from_payload()
        |> send_reply(stream)

        tx_loop(stream, ref, monitor)

      {:tx_error, ^ref, reason} ->
        TransactionUpdate.new(error: format_error(reason))
        |> send_reply(stream)

        tx_loop(stream, ref, monitor)

      {:overload, ^ref, scope} ->
        raise_rpc_error({:backpressure, scope})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok

      {:slot_update, _, _} ->
        tx_loop(stream, ref, monitor)
    after
      30_000 ->
        tx_loop(stream, ref, monitor)
    end
  end

  defp raise_rpc_error(:unauthenticated) do
    raise GRPC.RPCError, status: :unauthenticated, message: "Missing or invalid gRPC API key"
  end

  defp raise_rpc_error(:unauthorized) do
    raise GRPC.RPCError, status: :permission_denied, message: "API key not permitted for gRPC access"
  end

  defp raise_rpc_error(:rate_limited) do
    raise GRPC.RPCError, status: :resource_exhausted, message: "gRPC rate limit exceeded, try again later"
  end

  defp raise_rpc_error(:over_capacity) do
    raise GRPC.RPCError, status: :resource_exhausted, message: "gRPC capacity exhausted, please retry soon"
  end

  defp raise_rpc_error({:key_capacity, _key}) do
    raise GRPC.RPCError, status: :resource_exhausted, message: "Too many concurrent streams for this API key"
  end

  defp raise_rpc_error({:backpressure, :slots}) do
    raise GRPC.RPCError, status: :resource_exhausted, message: "Slot stream closed due to client backpressure"
  end

  defp raise_rpc_error({:backpressure, :transactions}) do
    raise GRPC.RPCError, status: :resource_exhausted, message: "Transaction stream closed due to client backpressure"
  end

  defp raise_rpc_error(reason) do
    raise GRPC.RPCError, status: :internal, message: "Unexpected gRPC error: #{inspect(reason)}"
  end

  defp transaction_update_from_payload(payload) do
    TransactionUpdate.new(
      signature: payload.signature,
      address: payload.address,
      slot: payload.slot || 0,
      error: format_error(payload.err),
      block_time: payload.block_time || 0
    )
  end

  defp send_reply(message, stream) do
    GRPC.Server.send_reply(stream, message)
  rescue
    exception ->
      Logger.warn("[GRPC] Failed to send reply: #{inspect(exception)}")
      :ok
  end

  defp format_error(nil), do: ""
  defp format_error(""), do: ""
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp normalize_string(nil), do: nil
  defp normalize_string(str) when is_binary(str) do
    case String.trim(str) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp sanitize_limit(limit) when is_integer(limit) and limit > 0 do
    limit |> min(100) |> max(1)
  end

  defp sanitize_limit(_), do: 20
end
