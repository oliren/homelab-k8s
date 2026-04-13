# ══════════════════════════════════════════════════════════════════════
# talos.tf
# Generates Talos machine configs, applies them to each node via the
# Talos API, bootstraps etcd on the first control plane, waits for
# cluster health, then fetches the kubeconfig.
#
# No SSH. No Ansible. No shell scripts. Pure API.
# ══════════════════════════════════════════════════════════════════════

# ── 1. Cluster secrets ────────────────────────────────────────────────
# Generates all PKI material: CA certs, etcd certs, bootstrap tokens.
# This resource creates a unique secret bundle for the cluster.
# ⚠️  CRITICAL: Back up your Terraform state — losing it = losing cluster PKI!
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# ── 2. Client configuration ───────────────────────────────────────────
# Generates the talosconfig file (equivalent of kubeconfig, but for talosctl)
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration

  # All node IPs — talosctl can target any of them
  nodes = concat(var.cp_ips, [var.worker_pve1_ip, var.worker_pve2_ip])

  # Control plane IPs only — these are the API endpoints
  endpoints = var.cp_ips
}

# ── 3. Machine configurations ─────────────────────────────────────────
# Generates a machine config YAML for each node.
# Control planes get the controlplane patch; workers get the worker patch.
# Each node also gets a hostname patch injected inline.
data "talos_machine_configuration" "this" {
  for_each = local.nodes

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.cluster_vip}:6443"
  talos_version    = var.talos_version
  machine_type     = each.value.machine_type
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = each.value.machine_type == "controlplane" ? [
    # Shared controlplane config: VIP, disable kube-proxy, no CNI (Cilium handles it)
    file("${path.module}/../talos/patches/controlplane.yaml"),
    # Per-node hostname
    yamlencode({
      machine = {
        network = {
          hostname = each.key
        }
      }
    })
  ] : [
    # Worker config
    file("${path.module}/../talos/patches/worker.yaml"),
    # Per-node hostname
    yamlencode({
      machine = {
        network = {
          hostname = each.key
        }
      }
    })
  ]
}

# ── 4. Apply machine configs to all nodes ─────────────────────────────
# Pushes the generated YAML to each node's Talos API on port 50000.
# The node applies it, writes config to disk, and reboots.
# This replaces the entire "Ansible + SSH" step from traditional setups.
resource "talos_machine_configuration_apply" "this" {
  # Wait until VMs exist and have booted into maintenance mode
  depends_on = [proxmox_virtual_environment_vm.nodes]

  for_each = local.nodes

  node                        = each.value.ip
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration

  lifecycle {
    # Re-apply config if the VM is recreated (e.g. during upgrade)
    replace_triggered_by = [proxmox_virtual_environment_vm.nodes[each.key]]
  }
}

# ── 5. Bootstrap etcd ─────────────────────────────────────────────────
# Initialises the etcd cluster on the FIRST control plane node only.
# ⚠️  This must only ever be run ONCE per cluster lifetime.
#     Terraform's state prevents accidental re-runs.
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.this]

  # Always bootstrap via cp-1
  node                 = var.cp_ips[0]
  endpoint             = var.cp_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration
}

# ── 6. Wait for cluster health ────────────────────────────────────────
# Polls the Talos API until all nodes are healthy and etcd has quorum.
# Typically takes 3-8 minutes on first boot.
data "talos_cluster_health" "this" {
  depends_on = [
    talos_machine_configuration_apply.this,
    talos_machine_bootstrap.this,
  ]

  client_configuration = data.talos_client_configuration.this.client_configuration
  control_plane_nodes  = var.cp_ips
  worker_nodes         = [var.worker_pve1_ip, var.worker_pve2_ip]
  endpoints            = data.talos_client_configuration.this.endpoints

  timeouts = {
    read = "15m"  # Give it enough time on first boot
  }
}

# ── 7. Fetch kubeconfig ───────────────────────────────────────────────
# Retrieves the kubeconfig from the cluster once it's healthy.
data "talos_cluster_kubeconfig" "this" {
  depends_on = [
    talos_machine_bootstrap.this,
    data.talos_cluster_health.this,
  ]

  node                 = var.cp_ips[0]
  endpoint             = var.cluster_vip  # Use the VIP — not a single node IP
  client_configuration = talos_machine_secrets.this.client_configuration

  timeouts = {
    read = "5m"
  }
}
