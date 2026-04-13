# ══════════════════════════════════════════════════════════════════════
# outputs.tf
# Writes talosconfig and kubeconfig to the output/ directory.
# Also exposes them as Terraform outputs for scripting.
# ══════════════════════════════════════════════════════════════════════

# Write talosconfig to disk (used by talosctl)
resource "local_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/../output/talosconfig"
  file_permission = "0600"  # Private — contains cluster PKI material
}

# Write kubeconfig to disk (used by kubectl, helm, flux, etc.)
resource "local_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/../output/kubeconfig"
  file_permission = "0600"  # Private — grants cluster-admin access
}

# ── Console outputs ───────────────────────────────────────────────────

output "talosconfig" {
  description = "Talos client configuration (talosconfig). Also written to output/talosconfig."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubernetes client configuration (kubeconfig). Also written to output/kubeconfig."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "cluster_vip" {
  description = "Kubernetes API server endpoint (VIP)"
  value       = "https://${var.cluster_vip}:6443"
}

output "node_summary" {
  description = "Summary of all nodes and their IPs"
  value = {
    control_planes = {
      "talos-cp-1 (pve1)" = var.cp_ips[0]
      "talos-cp-2 (pve1)" = var.cp_ips[1]
      "talos-cp-3 (pve1)" = var.cp_ips[2]
    }
    workers = {
      "talos-worker-1 (pve1)" = var.worker_pve1_ip
      "talos-worker-2 (pve2)" = var.worker_pve2_ip
    }
  }
}
