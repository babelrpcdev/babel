#!/bin/bash
# Solana validator optimization script for pump.fun trading

# System tuning
ulimit -n 1000000

# Network buffer tuning
sysctl -w net.core.rmem_max=134217728 || true
sysctl -w net.core.wmem_max=134217728 || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" || true

# Disable transparent huge pages for better memory management
echo never > /sys/kernel/mm/transparent_hugepage/enabled || true

echo "Solana validator optimizations applied"

