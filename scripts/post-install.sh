#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# post-install.sh
# Run this AFTER terraform apply succeeds.
# Installs Cilium CNI and Longhorn storage into the cluster.
#
# Usage:
#   source scripts/setup-env.sh   # set KUBECONFIG etc.
#   bash scripts/post-install.sh
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Sanity checks ─────────────────────────────────────────────────────
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "❌ KUBECONFIG not set. Run: source scripts/setup-env.sh"
  exit 1
fi

if ! kubectl get nodes &>/dev/null; then
  echo "❌ Cannot reach cluster. Check KUBECONFIG and VIP."
  exit 1
fi

echo "🚀 Starting post-install setup..."
echo ""

# ── Step 1: Install Cilium ────────────────────────────────────────────
echo "📦 Step 1/4: Installing Cilium CNI..."

helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --values "${PROJECT_ROOT}/kubernetes/cilium/values.yaml" \
  --wait \
  --timeout 5m

echo "✅ Cilium installed. Waiting for nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=5m
echo ""

# ── Step 2: Apply Cilium IP Pool ─────────────────────────────────────
echo "📦 Step 2/4: Configuring Cilium LoadBalancer IP pool..."
kubectl apply -f "${PROJECT_ROOT}/kubernetes/cilium/ip-pool.yaml"
echo "✅ IP pool applied."
echo ""

# ── Step 3: Install Longhorn ──────────────────────────────────────────
echo "📦 Step 3/4: Installing Longhorn storage..."

helm repo add longhorn https://charts.longhorn.io --force-update
helm repo update longhorn

helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultReplicaCount=2 \
  --set defaultSettings.storageMinimalAvailablePercentage=15 \
  --set defaultSettings.storageReservedPercentageForDefaultDisk=25 \
  --wait \
  --timeout 10m

echo "✅ Longhorn installed."
echo ""

# ── Step 4: Install cert-manager ──────────────────────────────────────
echo "📦 Step 4/4: Installing cert-manager..."

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait \
  --timeout 5m

echo "✅ cert-manager installed."
echo ""

# ── Summary ───────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
echo "✅ Post-install complete!"
echo ""
echo "Cluster status:"
kubectl get nodes -o wide
echo ""
echo "Cilium status:"
cilium status 2>/dev/null || echo "  (install cilium CLI to check: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/)"
echo ""
echo "Next steps:"
echo "  • Longhorn UI:   kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80"
echo "  • Hubble UI:     kubectl port-forward -n kube-system svc/hubble-ui 12000:80"
echo "  • Verify health: talosctl health"
echo "══════════════════════════════════════════════════════"
