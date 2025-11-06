#!/bin/bash
set -e

# Configuration
NETWORK="${SOLANA_NETWORK:-mainnet-beta}"
RPC_THREADS="${RPC_THREADS:-16}"
ACCOUNT_INDEX="${ACCOUNT_INDEX:-spl-token-owner,spl-token-mint}"
HISTORY="${HISTORY:-full}"

echo "Starting Babel Solana RPC Node"
echo "Network: $NETWORK"
echo "RPC Threads: $RPC_THREADS"

# Determine entrypoint based on network
case "$NETWORK" in
  mainnet-beta)
    ENTRYPOINT="https://api.mainnet-beta.solana.com"
    ;;
  devnet)
    ENTRYPOINT="https://api.devnet.solana.com"
    ;;
  testnet)
    ENTRYPOINT="https://api.testnet.solana.com"
    ;;
  *)
    ENTRYPOINT="$NETWORK"
    ;;
esac

# Download genesis if needed
if [ ! -f "/ledger/genesis.bin" ]; then
    echo "Downloading genesis for $NETWORK..."
    solana genesis-hash --url "$ENTRYPOINT" || true
    solana-validator --ledger /ledger init --no-voting --no-identity || true
fi

# Build command with optimizations for pump.fun trading
CMD="solana-validator \
  --ledger /ledger \
  --accounts /accounts \
  --snapshots /snapshots \
  --entrypoint ${ENTRYPOINT} \
  --no-voting \
  --no-poh-speed-test \
  --no-genesis-fetch \
  --no-snapshot-fetch \
  --private-rpc \
  --only-known-rpc \
  --rpc-port 8899 \
  --rpc-bind-address 0.0.0.0 \
  --enable-rpc-transaction-history \
  --enable-extended-tx-metadata-storage \
  --rpc-pubsub-enable-block-subscription \
  --rpc-pubsub-enable-vote-subscription \
  --enable-rpc-bigtable-ledger-storage \
  --rpc-threads ${RPC_THREADS} \
  --account-index ${ACCOUNT_INDEX} \
  --account-index-exclude-key kinXdEcpDQeHPEuQnqmUgtYykqKGVFq6CeVX5iAHJq6 \
  --full-rpc-api \
  --no-port-check \
  --no-wait-for-vote-to-start-leader \
  --maximum-local-snapshot-age 500 \
  --minimal-snapshot-download-speed 104857600 \
  --wal-recovery-mode skip_any_corrupted_record \
  --limit-ledger-size 50000000 \
  --block-production-method central-scheduler \
  --full-snapshot-interval-slots 25000 \
  --incremental-snapshot-interval-slots 1000 \
  --maximum-snapshots-to-retain 5 \
  --log -"

# Add program-specific indices for pump.fun
# Pump.fun program ID: 6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P
CMD="$CMD --account-index program-id"

# Health metrics
CMD="$CMD --health-check-slot-distance 150"

# Start validator
echo "Starting Solana RPC with command:"
echo "$CMD"

exec $CMD

