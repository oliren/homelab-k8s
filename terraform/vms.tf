# ══════════════════════════════════════════════════════════════════════
# vms.tf
# Defines all 5 Talos VMs spread across pve1 and pve2.
#
# WHY TWO SEPARATE RESOURCE BLOCKS?
# Terraform's `provider` meta-argument must be a static literal — you
# cannot dynamically select a provider using for_each values like
# `provider = proxmox[each.value.host]`. Each provider alias requires
# its own resource block with an explicit `provider = proxmox.<alias>`.
#
# pve1 (i3-1115G4 / 64 GB) — main host:
#   talos-cp-1       Control Plane   2 vCPU   4 GB    50 GB
#   talos-cp-2       Control Plane   2 vCPU   4 GB    50 GB
#   talos-cp-3       Control Plane   2 vCPU   4 GB    50 GB
#   talos-worker-1   Worker          2 vCPU  20 GB   100 GB
#
# pve2 (N100 / 16 GB — OPNsense lives here!) — light worker only:
#   talos-worker-2   Worker          2 vCPU   6 GB    60 GB  ← RAM FIXED, no balloon
#
# ══════════════════════════════════════════════════════════════════════

locals {

  # ── pve1 node definitions ──────────────────────────────────────────
  # 3 control planes + 1 worker — all on the Intel NUC (64 GB RAM)
  nodes_pve1 = {

    "talos-cp-1" = {
      machine_type = "controlplane"
      vm_id        = 801
      ip           = var.cp_ips[0]
      mac          = "BC:24:11:00:00:01"
      cpu          = 2
      ram          = 4096
      disk_gb      = 50
      datastore    = var.pve1_datastore
    }

    "talos-cp-2" = {
      machine_type = "controlplane"
      vm_id        = 802
      ip           = var.cp_ips[1]
      mac          = "BC:24:11:00:00:02"
      cpu          = 2
      ram          = 4096
      disk_gb      = 50
      datastore    = var.pve1_datastore
    }

    "talos-worker-1" = {
      machine_type = "worker"
      vm_id        = 811
      ip           = var.worker_pve1_ip
      mac          = "BC:24:11:00:00:11"
      cpu          = 2
      ram          = 20480
      disk_gb      = 100
      datastore    = var.pve1_datastore
    }

    "talos-worker-2" = {
      machine_type = "worker"
      vm_id        = 812
      ip           = var.worker_pve2_ip
      mac          = "BC:24:11:00:00:12"
      cpu          = 2
      ram          = 6144   # FIXED — no ballooning. Protects OPNsense.
      disk_gb      = 60
      datastore    = var.pve2_datastore
    }
  }

  # ── pve2 node definitions ──────────────────────────────────────────
  # Only 1 light worker — the N100 host also runs OPNsense (your gateway!)
  # RAM budget: 6 GB worker + 4 GB OPNsense + 2 GB host + 4 GB buffer = 16 GB
  nodes_pve2 = {

    "talos-cp-3" = {
      machine_type = "controlplane"
      vm_id        = 803
      ip           = var.cp_ips[2]
      mac          = "BC:24:11:00:00:03"
      cpu          = 2
      ram          = 4096
      disk_gb      = 50
      datastore    = var.pve1_datastore
    }
  }

  # ── Merged map ────────────────────────────────────────────────────
  # Used by talos.tf to iterate over all nodes regardless of host.
  # Contains only the fields needed by Talos (machine_type + ip).
  nodes = merge(local.nodes_pve1, local.nodes_pve2)
}

# ══════════════════════════════════════════════════════════════════════
# VMs on pve1 — provider must be a static literal, not dynamic
# ══════════════════════════════════════════════════════════════════════
resource "proxmox_virtual_environment_vm" "nodes_pve1" {
  provider = proxmox.pve1
  for_each = local.nodes_pve1

  node_name   = "pve1"
  name        = each.key
  description = "Talos Linux ${each.value.machine_type} — managed by Terraform. DO NOT edit manually."
  tags        = ["talos", "k8s", each.value.machine_type]
  vm_id       = each.value.vm_id
  on_boot     = true

  machine       = "q35"
  bios          = "seabios"
  scsi_hardware = "virtio-scsi-single"

  # QEMU guest agent — lets Proxmox UI show VM IP, hostname, status
  # Requires qemu-guest-agent extension baked into the Talos image
  agent {
    enabled = true
    trim    = true
  }

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  memory {
    dedicated = each.value.ram
    floating  = 0  # No ballooning
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = each.value.mac
    # Fixed MACs → OPNsense static DHCP leases survive VM recreation
  }

  # Boot disk: the Talos raw image is imported from the Proxmox ISO
  # store and resized to disk_gb. This is the entire OS — no installer.
  disk {
    datastore_id = each.value.datastore
    interface    = "scsi0"
    file_id      = proxmox_download_file.talos_image_pve1.id
    file_format  = "raw"
    size         = each.value.disk_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  boot_order = ["scsi0"]

  operating_system {
    type = "l26"
  }

  # Static IP passed to Talos via the nocloud datasource (no SSH needed)
  initialization {
    datastore_id = each.value.datastore

    dns {
      servers = [var.cluster_dns]  # Pi-hole on rpi1
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.cluster_subnet}"
        gateway = var.cluster_gateway  # OPNsense LAN IP
      }
    }
  }

  lifecycle {
    ignore_changes = [
      disk, # Talos modifies disk at runtime — ignore drift
    ]
  }
}

# ══════════════════════════════════════════════════════════════════════
# VMs on pve2 — separate resource block required for provider alias
# ⚠️  This host runs OPNsense — RAM is intentionally capped!
# ══════════════════════════════════════════════════════════════════════
resource "proxmox_virtual_environment_vm" "nodes_pve2" {
  provider = proxmox.pve2
  for_each = local.nodes_pve2

  node_name   = "pve2"
  name        = each.key
  description = "Talos Linux ${each.value.machine_type} — managed by Terraform. DO NOT edit manually."
  tags        = ["talos", "k8s", each.value.machine_type]
  vm_id       = each.value.vm_id
  on_boot     = true

  machine       = "q35"
  bios          = "seabios"
  scsi_hardware = "virtio-scsi-single"

  agent {
    enabled = true
    trim    = true
  }

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  # ⚠️  RAM MUST stay fixed at 6 GB — no floating/balloon.
  # OPNsense on this same host needs guaranteed headroom.
  memory {
    dedicated = each.value.ram
    floating  = 0
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = each.value.mac
  }

  disk {
    datastore_id = each.value.datastore
    interface    = "scsi0"
    file_id      = proxmox_download_file.talos_image_pve2.id
    file_format  = "raw"
    size         = each.value.disk_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  boot_order = ["scsi0"]

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = each.value.datastore

    dns {
      servers = [var.cluster_dns]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.cluster_subnet}"
        gateway = var.cluster_gateway
      }
    }
  }

  lifecycle {
    ignore_changes = [
      disk,
    ]
  }
}
