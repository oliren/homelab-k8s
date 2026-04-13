# ══════════════════════════════════════════════════════════════════════
# talos.tf
# Generates Talos machine configs, applies them to each node via the
# Talos API, bootstraps etcd on the first control plane, then fetches
# the kubeconfig.
#
# No SSH. No Ansible. No shell scripts. Pure API.
#
# WHY NO talos_cluster_health?
# talos_cluster_health polls Talos until ALL nodes are fully healthy —
# including kubelet Ready state. In our setup, Cilium (CNI) and any
# post-install components must be running before nodes reach Ready.
# Those are installed by post-install.sh AFTER terraform finishes.
# Keeping talos_cluster_health in Terraform creates a deadlock:
#
#   terraform waits for health
#     └── health waits for nodes Ready
#           └── nodes need Cilium (CNI)
#                 └── Cilium installed by post-install.sh
#                       └── post-install.sh needs terraform to finish 💀
#
# Solution: Terraform only ensures etcd is bootstrapped and the API
# server is reachable (enough to fetch kubeconfig). Full cluster health
# is verified manually after post-install.sh with `talosctl health`.
# ══════════════════════════════════════════════════════════════════════

# ── 1. Cluster secrets ────────────────────────────────────────────────
# Generates all PKI material: CA certs, etcd certs, bootstrap tokens.
# ⚠️  CRITICAL: Back up your Terraform state — losing it = losing cluster PKI!
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# ── 2. Client configuration ───────────────────────────────────────────
# Generates the talosconfig file (like kubeconfig, but for talosctl)
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration

  # All node IPs — talosctl can target any of them
  nodes = concat(var.cp_ips, [var.worker_pve1_ip, var.worker_pve2_ip])

  # Control plane IPs only — used as API endpoints
  endpoints = var.cp_ips
}

# ── 3. Machine configurations ─────────────────────────────────────────
# Generates a machine config YAML for each node.
# Uses local.nodes (merged pve1 + pve2 map) to iterate all nodes.
# Control planes get the controlplane patch; workers get the worker patch.
data "talos_machine_configuration" "this" {
  for_each = local.nodes

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.cluster_vip}:6443"
  talos_version    = var.talos_version
  machine_type     = each.value.machine_type
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  # WHY NO HOSTNAME PATCH?
  # The bpg/proxmox `initialization` block causes Proxmox to generate a
  # cloud-init meta-data file containing `local-hostname: <vm-name>`.
  # Talos reads this on boot (nocloud platform) and sets the hostname
  # internally before we ever call talos_machine_configuration_apply.
  # If we also set machine.network.hostname in a patch, Talos throws:
  #   "static hostname is already set in v1alpha1 config"
  # Solution: let Proxmox cloud-init own the hostname — it already equals
  # the VM name (each.key), which is exactly what we want.
  config_patches = each.value.machine_type == "controlplane" ? [
    # CP config: VIP, disable kube-proxy, no CNI (Cilium installs later)
    file("${path.module}/../talos/patches/controlplane.yaml"),
  ] : [
    # Worker config: Longhorn mounts, sysctls
    file("${path.module}/../talos/patches/worker.yaml"),
  ]
}

# ── 4. Apply machine configs to all nodes ─────────────────────────────
# Pushes the generated YAML to each node's Talos API on port 50000.
# The node applies the config, writes it to disk, and reboots.
# This replaces the entire "Ansible + SSH" step from traditional setups.
#
# WHY depends_on LISTS BOTH RESOURCE BLOCKS?
# VMs are split into nodes_pve1 and nodes_pve2 (two separate resource
# blocks) because Terraform requires static provider references.
# We must depend on both to ensure all VMs exist before applying config.
resource "talos_machine_configuration_apply" "this" {
  depends_on = [
    proxmox_virtual_environment_vm.nodes_pve1,
    proxmox_virtual_environment_vm.nodes_pve2,
  ]

  for_each = local.nodes

  node                        = each.value.ip
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration

  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.nodes_pve1,
      proxmox_virtual_environment_vm.nodes_pve2,
    ]
  }
}

# ── 5. Bootstrap etcd ─────────────────────────────────────────────────
# Initialises the etcd cluster on the FIRST control plane node only.
# ⚠️  This must only ever run ONCE per cluster lifetime.
#     Terraform's state prevents accidental re-runs after the first apply.
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.this]

  node                 = var.cp_ips[0]  # Always bootstrap via cp-1
  endpoint             = var.cp_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration
}

# ── 6. Fetch kubeconfig ───────────────────────────────────────────────
# Retrieves the kubeconfig once the API server is reachable.
# Depends only on bootstrap — does NOT wait for full node health.
# Full health is verified after post-install.sh with `talosctl health`.
#
# NOTE: Using `resource` not `data` — the data source is deprecated as of
# siderolabs/talos ~> 0.7 and will be removed in the next minor version.
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  node                 = var.cp_ips[0]
  endpoint             = var.cluster_vip  # Use the VIP — not a single node IP
  client_configuration = talos_machine_secrets.this.client_configuration

  timeouts = {
    create = "5m"
  }
}
