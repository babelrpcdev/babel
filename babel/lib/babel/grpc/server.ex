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
  field :snapshot, 5, type: :bool
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
  field :snapshot, 6, type: :bool
end

defmodule Babel.GRPC.Stream.AccountUpdateStatus do
  use Protobuf, enum: true, syntax: :proto3

  field :ACCOUNT_STATUS_UNKNOWN, 0
  field :ACCOUNT_STATUS_EXISTS, 1
  field :ACCOUNT_STATUS_NOT_FOUND, 2
end

defmodule Babel.GRPC.Stream.AccountRequest do
  use Protobuf, syntax: :proto3

  field :address, 1, type: :string
  field :commitment, 2, type: :string
end

defmodule Babel.GRPC.Stream.AccountUpdate do
  use Protobuf, syntax: :proto3

  field :address, 1, type: :string
  field :slot, 2, type: :uint64
  field :lamports, 3, type: :uint64
  field :owner, 4, type: :string
  field :data, 5, type: :bytes
  field :encoding, 6, type: :string
  field :executable, 7, type: :bool
  field :rent_epoch, 8, type: :uint64, json_name: "rentEpoch"
  field :snapshot, 9, type: :bool
  field :status, 10, type: Babel.GRPC.Stream.AccountUpdateStatus, enum: true
end

defmodule Babel.GRPC.Stream.ProgramFilter do
  use Protobuf, syntax: :proto3

  field :memcmp_offset, 1, type: :uint32, json_name: "memcmpOffset"
  field :memcmp_bytes, 2, type: :string, json_name: "memcmpBytes"
  field :data_size, 3, type: :uint64, json_name: "dataSize"
end

defmodule Babel.GRPC.Stream.ProgramRequest do
  use Protobuf, syntax: :proto3

  field :program_id, 1, type: :string, json_name: "programId"
  field :commitment, 2, type: :string
  field :filters, 3, repeated: true, type: Babel.GRPC.Stream.ProgramFilter
end

defmodule Babel.GRPC.Stream.ProgramUpdateStatus do
  use Protobuf, enum: true, syntax: :proto3

  field :PROGRAM_STATUS_UNKNOWN, 0
  field :PROGRAM_STATUS_UPDATED, 1
  field :PROGRAM_STATUS_DELETED, 2
end

defmodule Babel.GRPC.Stream.ProgramAccount do
  use Protobuf, syntax: :proto3

  field :address, 1, type: :string
  field :lamports, 2, type: :uint64
  field :owner, 3, type: :string
  field :data, 4, type: :bytes
  field :encoding, 5, type: :string
  field :executable, 6, type: :bool
  field :rent_epoch, 7, type: :uint64, json_name: "rentEpoch"
end

defmodule Babel.GRPC.Stream.ProgramUpdate do
  use Protobuf, syntax: :proto3

  field :program_id, 1, type: :string, json_name: "programId"
  field :status, 2, type: Babel.GRPC.Stream.ProgramUpdateStatus, enum: true
  field :account, 3, type: Babel.GRPC.Stream.ProgramAccount
  field :slot, 4, type: :uint64
  field :snapshot, 5, type: :bool
end

defmodule Babel.GRPC.Stream.Service do
  use GRPC.Service, name: "babel.stream.BabelStream"

  rpc :SubscribeSlots, Babel.GRPC.Stream.SlotRequest, stream(Babel.GRPC.Stream.SlotUpdate)
  rpc :SubscribeTransactions, Babel.GRPC.Stream.TransactionRequest, stream(Babel.GRPC.Stream.TransactionUpdate)
  rpc :SubscribeAccounts, Babel.GRPC.Stream.AccountRequest, stream(Babel.GRPC.Stream.AccountUpdate)
  rpc :SubscribePrograms, Babel.GRPC.Stream.ProgramRequest, stream(Babel.GRPC.Stream.ProgramUpdate)
end

defmodule Babel.GRPC.Server do
  use GRPC.Server, service: Babel.GRPC.Stream.Service

  require Logger

  alias Babel.GRPC.{Auth, Streamer}
  alias Babel.GRPC.Stream.{AccountRequest, AccountUpdate, ProgramAccount, ProgramRequest, ProgramUpdate, SlotRequest,
    SlotUpdate, TransactionRequest, TransactionUpdate}

  @impl true
  def subscribe_slots(%SlotRequest{starting_slot: starting_slot}, stream) do
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
  def subscribe_transactions(%TransactionRequest{} = request, stream) do
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

  @impl true
  def subscribe_accounts(%AccountRequest{} = request, stream) do
    opts = %{
      address: normalize_string(request.address),
      commitment: normalize_string(request.commitment)
    }

    with {:ok, ctx} <- Auth.authorize(stream.metadata),
         {:ok, ref} <- Streamer.register_account(self(), opts, ctx) do
      Logger.debug("[GRPC] Account subscription registered (address=#{opts.address}, key=#{ctx.key})")
      monitor = Process.monitor(stream.pid)

      try do
        account_loop(stream, ref, monitor)
      after
        Streamer.unregister(ref)
      end
    else
      {:error, reason} ->
        raise_rpc_error(reason)
    end
  end

  @impl true
  def subscribe_programs(%ProgramRequest{} = request, stream) do
    opts = %{
      program_id: normalize_string(request.program_id),
      commitment: normalize_string(request.commitment),
      filters: request.filters |> Enum.map(&program_filter_to_map/1)
    }

    with {:ok, ctx} <- Auth.authorize(stream.metadata),
         {:ok, ref} <- Streamer.register_program(self(), opts, ctx) do
      Logger.debug("[GRPC] Program subscription registered (program=#{opts.program_id}, key=#{ctx.key})")
      monitor = Process.monitor(stream.pid)

      try do
        program_loop(stream, ref, monitor)
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

      {:account_update, _, _} ->
        slot_loop(stream, ref, monitor)

      {:program_update, _, _} ->
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

      {:account_update, _, _} ->
        tx_loop(stream, ref, monitor)

      {:program_update, _, _} ->
        tx_loop(stream, ref, monitor)

      {:slot_update, _, _} ->
        tx_loop(stream, ref, monitor)
    after
      30_000 ->
        tx_loop(stream, ref, monitor)
    end
  end

  defp account_loop(stream, ref, monitor) do
    receive do
      {:account_update, ^ref, payload} ->
        payload
        |> account_update_from_payload()
        |> send_reply(stream)

        account_loop(stream, ref, monitor)

      {:account_error, ^ref, reason} ->
        Logger.warn("[GRPC] Account stream error: #{inspect(reason)}")
        raise_rpc_error(:internal)

      {:overload, ^ref, scope} ->
        raise_rpc_error({:backpressure, scope})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok

      _other ->
        account_loop(stream, ref, monitor)
    after
      30_000 ->
        account_loop(stream, ref, monitor)
    end
  end

  defp program_loop(stream, ref, monitor) do
    receive do
      {:program_update, ^ref, payload} ->
        payload
        |> program_update_from_payload()
        |> send_reply(stream)

        program_loop(stream, ref, monitor)

      {:overload, ^ref, scope} ->
        raise_rpc_error({:backpressure, scope})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok

      _other ->
        program_loop(stream, ref, monitor)
    after
      30_000 ->
        program_loop(stream, ref, monitor)
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

  defp raise_rpc_error({:backpressure, :accounts}) do
    raise GRPC.RPCError, status: :resource_exhausted, message: "Account stream closed due to client backpressure"
  end

  defp raise_rpc_error({:backpressure, :programs}) do
    raise GRPC.RPCError, status: :resource_exhausted, message: "Program stream closed due to client backpressure"
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
      block_time: payload.block_time || 0,
      snapshot: Map.get(payload, :snapshot, false)
    )
  end

  defp account_update_from_payload(payload) do
    AccountUpdate.new(
      address: payload.address,
      slot: payload.slot || 0,
      lamports: payload.lamports || 0,
      owner: payload.owner || "",
      data: payload.data || <<>>,
      encoding: payload.encoding || "base64",
      executable: payload.executable || false,
      rent_epoch: payload.rent_epoch || 0,
      snapshot: Map.get(payload, :snapshot, false),
      status: payload.status || :ACCOUNT_STATUS_UNKNOWN
    )
  end

  defp program_update_from_payload(payload) do
    ProgramUpdate.new(
      program_id: payload.program_id || "",
      status: payload.status || :PROGRAM_STATUS_UNKNOWN,
      account:
        ProgramAccount.new(
          address: get_in(payload, [:account, :address]) || "",
          lamports: get_in(payload, [:account, :lamports]) || 0,
          owner: get_in(payload, [:account, :owner]) || "",
          data: get_in(payload, [:account, :data]) || <<>>,
          encoding: get_in(payload, [:account, :encoding]) || "base64",
          executable: get_in(payload, [:account, :executable]) || false,
          rent_epoch: get_in(payload, [:account, :rent_epoch]) || 0
        ),
      slot: payload.slot || 0,
      snapshot: Map.get(payload, :snapshot, false)
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

  defp normalize_string(_), do: nil

  defp sanitize_limit(limit) when is_integer(limit) and limit > 0 do
    limit |> min(100) |> max(1)
  end

  defp sanitize_limit(_), do: 20

  defp program_filter_to_map(filter) do
    %{
      memcmp_offset: filter.memcmp_offset,
      memcmp_bytes: filter.memcmp_bytes |> normalize_string(),
      data_size: filter.data_size
    }
  end
end
