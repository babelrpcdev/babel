defmodule Babel.RPC.Client do
  use GenServer
  require Logger

  @rpc_endpoint System.get_env("RPC_ENDPOINT", "http://solana-rpc:8899")

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("Initializing RPC Client: #{@rpc_endpoint}")
    {:ok, %{endpoint: @rpc_endpoint, request_count: 0}}
  end

  # Public API
  def call(method, params \\ []) do
    GenServer.call(__MODULE__, {:rpc_call, method, params}, 30_000)
  end

  # Get slot information
  def get_slot do
    call("getSlot", [%{"commitment" => "confirmed"}])
  end

  # Get block height
  def get_block_height do
    call("getBlockHeight", [%{"commitment" => "confirmed"}])
  end

  # Get account info (optimized for token accounts)
  def get_account_info(pubkey) do
    call("getAccountInfo", [pubkey, %{"encoding" => "jsonParsed", "commitment" => "confirmed"}])
  end

  # Get token accounts by owner (critical for pump.fun)
  def get_token_accounts_by_owner(owner, opts \\ %{}) do
    call("getTokenAccountsByOwner", [
      owner,
      %{"programId" => "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"},
      Map.merge(%{"encoding" => "jsonParsed", "commitment" => "confirmed"}, opts)
    ])
  end

  # Get recent performance samples
  def get_recent_performance_samples(limit \\ 10) do
    call("getRecentPerformanceSamples", [limit])
  end

  # Get signatures for address (transaction history)
  def get_signatures_for_address(address, opts \\ %{}) do
    call("getSignaturesForAddress", [address, opts])
  end

  # Get transaction with metadata
  def get_transaction(signature, opts \\ %{}) do
    default_opts = %{
      "encoding" => "jsonParsed",
      "commitment" => "confirmed",
      "maxSupportedTransactionVersion" => 0
    }
    call("getTransaction", [signature, Map.merge(default_opts, opts)])
  end

  # Get program accounts (for pump.fun program monitoring)
  def get_program_accounts(program_id, opts \\ %{}) do
    call("getProgramAccounts", [
      program_id,
      Map.merge(%{"encoding" => "jsonParsed", "commitment" => "confirmed"}, opts)
    ])
  end

  # Health check
  def get_health do
    call("getHealth", [])
  end

  # Get version
  def get_version do
    call("getVersion", [])
  end

  @impl true
  def handle_call({:rpc_call, method, params}, _from, state) do
    start_time = System.monotonic_time(:microsecond)
    
    result = make_request(state.endpoint, method, params)
    
    duration = System.monotonic_time(:microsecond) - start_time
    
    # Emit telemetry
    :telemetry.execute(
      [:babel, :rpc, :request],
      %{duration: duration},
      %{method: method, status: elem(result, 0)}
    )

    new_state = %{state | request_count: state.request_count + 1}
    {:reply, result, new_state}
  end

  defp make_request(endpoint, method, params) do
    payload = Jason.encode!(%{
      jsonrpc: "2.0",
      id: 1,
      method: method,
      params: params
    })

    headers = [
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"result" => result}} -> {:ok, result}
          {:ok, %{"error" => error}} -> {:error, error}
          {:error, _} = error -> error
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "HTTP #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end
end

