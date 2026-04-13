#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# upgrade-talos.sh
# Performs a rolling Talos OS upgrade across all nodes.
# Upgrades one node at a time — cluster stays alive throughout.
#
# Usage:
#   source scripts/setup-env.sh
#   bash scripts/upgrade-talos.sh <new-version> <schematic-id>
#
# Example:
#   bash scripts/upgrade-talos.sh v1.10.0 abc123def456...
#
# Find schematic ID: terraform output (or check Image Factory)
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail

NEW_VERSION="${1:-}"
SCHEMATIC_ID="${2:-}"

if [[ -z "$NEW_VERSION" || -z "$SCHEMATIC_ID" ]]; then
  echo "Usage: $0 <new-talos-version> <schematic-id>"
  echo "Example: $0 v1.10.0 abc123def456789..."
  exit 1
fi

INSTALLER_IMAGE="factory.talos.dev/installer/${SCHEMATIC_ID}:${NEW_VERSION}"

# All node IPs — workers first, control planes last
WORKER_NODES=("192.168.1.111" "192.168.1.112")
CP_NODES=("192.168.1.101" "192.168.1.102" "192.168.1.103")

echo "🔄 Starting rolling Talos upgrade to ${NEW_VERSION}"
echo "   Installer: ${INSTALLER_IMAGE}"
echo ""

upgrade_node() {
  local ip="$1"
  local role="$2"
  local name="$3"

  echo "──────────────────────────────────────────────────"
  echo "⬆️  Upgrading ${name} (${role}) at ${ip}..."

  # Drain the node if it's a worker
  if [[ "$role" == "worker" ]]; then
    echo "   Draining node..."
    kubectl drain "${name}" \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --timeout=120s || echo "   ⚠️  Drain had warnings (continuing)"
  fi

  # Upgrade Talos on this node
  talosctl upgrade \
    --nodes "${ip}" \
    --image "${INSTALLER_IMAGE}" \
    --preserve=true \
    --wait=true

  # Re-enable scheduling if worker
  if [[ "$role" == "worker" ]]; then
    echo "   Uncordoning node..."
    kubectl uncordon "${name}"
  fi

  echo "✅ ${name} upgraded successfully"
  echo ""

  # Brief pause between nodes
  sleep 10
}

# Upgrade workers first (lower risk)
for ip in "${WORKER_NODES[@]}"; do
  case "$ip" in
    "192.168.1.111") upgrade_node "$ip" "worker" "talos-worker-1" ;;
    "192.168.1.112") upgrade_node "$ip" "worker" "talos-worker-2" ;;
  esac
done

# Upgrade control planes one at a time (preserve quorum!)
for ip in "${CP_NODES[@]}"; do
  case "$ip" in
    "192.168.1.101") upgrade_node "$ip" "controlplane" "talos-cp-1" ;;
    "192.168.1.102") upgrade_node "$ip" "controlplane" "talos-cp-2" ;;
    "192.168.1.103") upgrade_node "$ip" "controlplane" "talos-cp-3" ;;
  esac
  echo "Waiting for etcd quorum to stabilise..."
  sleep 30
done

echo "══════════════════════════════════════════════════"
echo "✅ All nodes upgraded to ${NEW_VERSION}"
echo ""
kubectl get nodes -o wide
echo ""
talosctl version --nodes 192.168.1.101,192.168.1.111
