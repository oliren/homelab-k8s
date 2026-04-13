#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# setup-env.sh
# Sets environment variables needed by Terraform and talosctl.
#
# Usage:
#   source scripts/setup-env.sh
#
# Prerequisites — create API tokens in Proxmox:
#   Datacenter → Permissions → API Tokens → Add
#   User: root@pam
#   Token ID: terraform
#   Privilege Separation: NO (unchecked)
#
# ⚠️  Never commit this file with real tokens filled in!
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail

echo "Setting up Terraform + Talos environment..."

# ── Proxmox API Token ─────────────────────────────────────────────────
# Format: <user>@<realm>!<tokenid>=<uuid>
# If pve1 and pve2 share the same token (same Proxmox realm), use one.
# If they are separate Proxmox instances with separate tokens, you'll
# need to configure per-provider auth in providers.tf.
export PROXMOX_VE_API_TOKEN="root@pam!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# ← REPLACE with your actual token

# ── SSH Agent (needed by bpg/proxmox for image uploads) ──────────────
# Make sure your SSH key is added:
#   ssh-add ~/.ssh/id_rsa
if ! ssh-add -l &>/dev/null; then
  echo "⚠️  No SSH keys in agent. Run: ssh-add ~/.ssh/id_rsa"
fi

# ── Talos & Kubernetes config pointers ───────────────────────────────
# Set after first terraform apply creates these files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export TALOSCONFIG="${PROJECT_ROOT}/output/talosconfig"
export KUBECONFIG="${PROJECT_ROOT}/output/kubeconfig"

echo ""
echo "✅ Environment ready!"
echo ""
echo "   PROXMOX_VE_API_TOKEN = ${PROXMOX_VE_API_TOKEN:0:20}... (truncated)"
echo "   TALOSCONFIG          = ${TALOSCONFIG}"
echo "   KUBECONFIG           = ${KUBECONFIG}"
echo ""
echo "Next steps:"
echo "   cd terraform/"
echo "   cp terraform.tfvars.example terraform.tfvars"
echo "   # Edit terraform.tfvars with your IPs"
echo "   terraform init"
echo "   terraform plan"
echo "   terraform apply"
