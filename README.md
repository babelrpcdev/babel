# Babel - Private Solana RPC Node

Production-grade private RPC infrastructure for Solana mainnet, optimized for pump.fun memecoin trading.

## Architecture

- **Solana RPC Node**: Optimized mainnet validator with private RPC access
- **Babel Manager**: Elixir/OTP application for monitoring and management
- **gRPC Stream Service**: Low-latency slot and transaction feeds inspired by Yellowstone gRPC
- **Metrics Stack**: Prometheus + Grafana for real-time monitoring
- **Logging Stack**: Loki + Promtail for centralized log aggregation

## Quick Start

```bash
# Copy environment template
cp env.example .env

# Edit configuration (REQUIRED)
# Set API keys, passwords, and Erlang cookie
nano .env

# Start services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f babel-manager
```

## Access Points

- **RPC Endpoint**: `http://localhost:8899`
- **WebSocket**: `ws://localhost:8900`
- **Babel API**: `http://localhost:4000`
- **gRPC Stream**: `grpc://localhost:50051`
- **Grafana**: `http://localhost:3000` (default: admin/admin)
- **Prometheus**: `http://localhost:9090`

## API Usage

### Health Check
```bash
curl http://localhost:4000/health
```

### RPC Proxy (with API key)
```bash
curl -X POST http://localhost:4000/rpc \
  -H "X-API-Key: your_api_key" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[]}'
```

### Get Token Accounts (pump.fun optimized)
```bash
curl http://localhost:4000/pump/tokens/{WALLET_ADDRESS} \
  -H "X-API-Key: your_api_key"
```

## gRPC Streaming

The Babel Stream service follows a lightweight proto contract (`babel/proto/babel_stream.proto`) and exposes two real-time feeds:

- `SubscribeSlots` – continuous slot, TPS, and block-time updates
- `SubscribeTransactions` – recent signatures for any address or program (ideal for pump.fun tracking)

Example slot subscription using [`grpcurl`](https://github.com/fullstorydev/grpcurl):

```bash
grpcurl -plaintext \
  -d '{"startingSlot": 0}' \
  localhost:50051 babel.stream.BabelStream/SubscribeSlots
```

Watch pump.fun program signatures with throttled polling (defaults shown in `.env`):

```bash
grpcurl -plaintext \
  -d '{"address":"6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P","limit":20}' \
  localhost:50051 babel.stream.BabelStream/SubscribeTransactions
```

> After pulling the repository, run `mix deps.get` inside `babel/` to install the new gRPC dependencies.

## Performance Tuning

### Hardware Requirements
- **CPU**: 16+ cores (AMD Ryzen 9 or Intel Xeon recommended)
- **RAM**: 256GB+ (512GB recommended)
- **Storage**: 2TB+ NVMe SSD
- **Network**: 1 Gbps+ with low latency

### Environment Variables
```bash
RPC_THREADS=16              # Adjust based on CPU cores
ACCOUNT_INDEX=spl-token-owner,spl-token-mint,program-id
```

## Monitoring

Access Grafana at `http://localhost:3000` for:
- Node health and slot progression
- RPC request rates and latency
- Transaction throughput (TPS)
- System resources

## Scaling to Multi-Node

The architecture supports multi-node deployment:

1. Update `docker-compose.yml` to add more `solana-rpc` instances
2. Configure load balancing in Babel manager
3. Use shared storage for snapshots (NFS or S3)

## Security

- Change default passwords in `.env`
- Use strong API keys (generate with `openssl rand -hex 32`)
- Configure firewall rules (only expose necessary ports)
- Enable rate limiting in Babel manager

## Troubleshooting

### Node not syncing
```bash
docker-compose logs solana-rpc | tail -100
```

### Check Babel manager status
```bash
curl http://localhost:4000/status
```

### Reset node data
```bash
docker-compose down -v
docker-compose up -d
```

## License

MIT

