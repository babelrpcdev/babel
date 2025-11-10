defmodule Babel.GRPC.Auth do
  use GenServer
  require Logger

  @cleanup_interval :timer.minutes(1)
  @table :babel_grpc_auth_counters

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec authorize(map()) :: {:ok, %{key: String.t()}} | {:error, atom()}
  def authorize(metadata) when is_map(metadata) do
    GenServer.call(__MODULE__, {:authorize, metadata})
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:ok, %{config: load_config()}}
  end

  @impl true
  def handle_call({:authorize, metadata}, _from, state) do
    case authorize_internal(metadata, state.config) do
      {:ok, key} = result ->
        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    prune_counters()
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, %{state | config: maybe_reload(state.config)}}
  end

  ## Internal helpers

  defp authorize_internal(metadata, config) do
    with {:ok, key} <- extract_key(metadata, config),
         :ok <- enforce_rate_limit(key, config) do
      {:ok, %{key: key}}
    end
  end

  defp load_config do
    keys =
      System.get_env("GRPC_API_KEYS")
      |> to_string()
      |> String.split([",", "\n", "\t", " "], trim: true)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.trim/1)

    keys =
      case keys do
        [] ->
          case System.get_env("API_KEY") do
            nil -> []
            "" -> []
            key -> [String.trim(key)]
          end

        list ->
          list
      end

    %{
      keys: MapSet.new(keys),
      require_auth?: keys != [],
      rate_limit: env_int("GRPC_RATE_LIMIT_PER_MIN", 1200)
    }
  end

  defp maybe_reload(config) do
    new_config = load_config()

    if new_config == config do
      config
    else
      Logger.info("[GRPC] Auth config reloaded")
      new_config
    end
  end

  defp extract_key(metadata, %{keys: keys, require_auth?: require_auth?}) do
    normalized =
      metadata
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), v} end)
      |> Map.new()

    key =
      cond do
        value = Map.get(normalized, "x-api-key") -> value
        value = Map.get(normalized, "authorization") -> parse_authorization(value)
        true -> nil
      end
      |> normalize_key()

    cond do
      is_nil(key) and require_auth? ->
        {:error, :unauthenticated}

      is_nil(key) ->
        {:ok, "anonymous"}

      MapSet.size(keys) == 0 ->
        {:ok, key}

      MapSet.member?(keys, key) ->
        {:ok, key}

      true ->
        {:error, :unauthorized}
    end
  end

  defp enforce_rate_limit(_key, %{rate_limit: limit}) when limit <= 0, do: :ok

  defp enforce_rate_limit(key, %{rate_limit: limit}) do
    minute = System.system_time(:second) |> div(60)
    counter_key = {key, minute}

    count = :ets.update_counter(@table, counter_key, {2, 1}, {counter_key, 0})

    if count > limit do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp prune_counters do
    cutoff = System.system_time(:second) |> div(60) - 2

    match_spec = [
      {{{:"$1", :"$2"}, :"$3"}, [{:<, :"$2", cutoff}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
  end

  defp parse_authorization(value) when is_binary(value) do
    case String.split(String.trim(value), " ", parts: 2, trim: true) do
      [scheme, token] ->
        case String.downcase(scheme) do
          "bearer" -> token
          "apikey" -> token
          _ -> token
        end

      [single] ->
        single

      _ ->
        nil
    end
  end

  defp parse_authorization(_), do: nil

  defp normalize_key(nil), do: nil

  defp normalize_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_key(_), do: nil

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
end
