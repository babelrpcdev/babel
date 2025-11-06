defmodule Babel.API.Router do
  use Plug.Router
  require Logger
  alias Babel.RPC.Client
  alias Babel.Monitor

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # Health endpoint
  get "/health" do
    status = Monitor.get_status()
    
    response = %{
      healthy: status.healthy,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      slot: status.last_slot,
      metrics: status.metrics
    }

    send_json(conn, 200, response)
  end

  # Status endpoint with detailed information
  get "/status" do
    with {:ok, version} <- Client.get_version(),
         {:ok, slot} <- Client.get_slot(),
         {:ok, block_height} <- Client.get_block_height(),
         {:ok, performance} <- Client.get_recent_performance_samples(1) do
      
      [sample | _] = performance
      
      response = %{
        version: version,
        slot: slot,
        block_height: block_height,
        performance: %{
          tps: sample["numTransactions"] / sample["samplePeriodSecs"],
          num_transactions: sample["numTransactions"],
          sample_period: sample["samplePeriodSecs"]
        },
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      send_json(conn, 200, response)
    else
      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Proxy RPC calls
  post "/rpc" do
    api_key = get_req_header(conn, "x-api-key") |> List.first()
    
    if valid_api_key?(api_key) do
      case conn.body_params do
        %{"method" => method, "params" => params} ->
          case Client.call(method, params) do
            {:ok, result} ->
              send_json(conn, 200, %{
                jsonrpc: "2.0",
                id: conn.body_params["id"] || 1,
                result: result
              })

            {:error, error} ->
              send_json(conn, 200, %{
                jsonrpc: "2.0",
                id: conn.body_params["id"] || 1,
                error: %{code: -32603, message: inspect(error)}
              })
          end

        _ ->
          send_json(conn, 400, %{error: "Invalid request format"})
      end
    else
      send_json(conn, 401, %{error: "Unauthorized"})
    end
  end

  # Metrics endpoint for Prometheus
  get "/metrics" do
    metrics = Prometheus.Format.Text.format()
    
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  # Pump.fun specific endpoints
  get "/pump/tokens/:owner" do
    api_key = get_req_header(conn, "x-api-key") |> List.first()
    
    if valid_api_key?(api_key) do
      case Client.get_token_accounts_by_owner(owner) do
        {:ok, result} ->
          send_json(conn, 200, %{owner: owner, tokens: result})

        {:error, error} ->
          send_json(conn, 500, %{error: inspect(error)})
      end
    else
      send_json(conn, 401, %{error: "Unauthorized"})
    end
  end

  # Catch all
  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp valid_api_key?(nil), do: false
  defp valid_api_key?(key) do
    expected = System.get_env("API_KEY", "")
    key == expected && key != ""
  end
end

