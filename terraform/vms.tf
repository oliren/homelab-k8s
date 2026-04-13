# ══════════════════════════════════════════════════════════════════════
# vms.tf
# Defines all 5 Talos VMs spread across pve1 and pve2.
#
# pve1 (i3-1115G4 / 64 GB) — main host:
#   talos-cp-1       Control Plane   2 vCPU   4 GB   50 GB
#   talos-cp-2       Control Plane   2 vCPU   4 GB   50 GB
#   talos-cp-3       Control Plane   2 vCPU   4 GB   50 GB
#   talos-worker-1   Worker          2 vCPU  20 GB  100 GB
#
# pve2 (N100 / 16 GB — OPNsense lives here!) — light worker:
#   talos-worker-2   Worker          2 vCPU   6 GB   60 GB  ← RAM is FIXED, no balloon
#
# ══════════════════════════════════════════════════════════════════════

locals {
  nodes = {

    # ── Control Planes (all on pve1) ────────────────────────────────
    "talos-cp-1" = {
      pve_host     = "pve1"
      pve_node     = "pve1"
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
      pve_host     = "pve1"
      pve_node     = "pve1"
      machine_type = "controlplane"
      vm_id        = 802
      ip           = var.cp_ips[1]
      mac          = "BC:24:11:00:00:02"
      cpu          = 2
      ram          = 4096
      disk_gb      = 50
      datastore    = var.pve1_datastore
    }

    "talos-cp-3" = {
      pve_host     = "pve1"
      pve_node     = "pve1"
      machine_type = "controlplane"
      vm_id        = 803
      ip           = var.cp_ips[2]
      mac          = "BC:24:11:00:00:03"
      cpu          = 2
      ram          = 4096
      disk_gb      = 50
      datastore    = var.pve1_datastore
    }

    # ── Worker on pve1 (bulk workloads) ─────────────────────────────
    "talos-worker-1" = {
      pve_host     = "pve1"
      pve_node     = "pve1"
      machine_type = "worker"
      vm_id        = 811
      ip           = var.worker_pve1_ip
      mac          = "BC:24:11:00:00:11"
      cpu          = 2
      ram          = 20480
      disk_gb      = 100
      datastore    = var.pve1_datastore
    }

    # ── Worker on pve2 (light — OPNsense shares this host!) ─────────
    # RAM is intentionally capped at 6 GB with NO ballooning.
    # OPNsense needs ~4 GB + 2 GB host overhead = 10 GB reserved.
    # 6 GB worker + 4 GB OPNsense + 2 GB host + 4 GB buffer = 16 GB total
    "talos-worker-2" = {
      pve_host     = "pve2"
      pve_node     = "pve2"
      machine_type = "worker"
      vm_id        = 812
      ip           = var.worker_pve2_ip
      mac          = "BC:24:11:00:00:12"
      cpu          = 2
      ram          = 6144
      disk_gb      = 60
      datastore    = var.pve2_datastore
    }
  }
}

# ── Create all VMs ────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "nodes" {
  for_each = local.nodes

  # Route each VM to the correct Proxmox host
  # bpg/proxmox requires the node_name to match the Proxmox node name
  node_name = each.value.pve_node

  name        = each.key
  description = "Talos Linux ${each.value.machine_type} — managed by Terraform. DO NOT edit manually."
  tags        = ["talos", "k8s", each.value.machine_type]
  vm_id       = each.value.vm_id
  on_boot     = true     # Auto-start after Proxmox host reboot

  # q35 is the modern QEMU machine type — better PCIe support
  machine       = "q35"
  bios          = "seabios"
  scsi_hardware = "virtio-scsi-single"

  # QEMU guest agent — lets Proxmox see VM IP, hostname, status
  # Enabled by the qemu-guest-agent extension baked into our Talos image
  agent {
    enabled = true
    trim    = true
  }

  cpu {
    cores = each.value.cpu
    type  = "host"  # Pass through host CPU flags — best performance
  }

  # ⚠️  NO memory ballooning — dedicated fixed RAM only.
  # This is critical for talos-worker-2 on pve2 to protect OPNsense.
  memory {
    dedicated = each.value.ram
    floating  = 0  # Disable balloon driver completely
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = each.value.mac
    # Fixed MACs mean your DHCP/OPNsense static leases won't break on VM recreation
  }

  # Boot disk — Talos raw image imported from Proxmox ISO store
  # Proxmox copies + resizes the source image to this VM-specific disk
  disk {
    datastore_id = each.value.datastore
    interface    = "scsi0"
    file_id      = local.image_file_ids[each.value.pve_host]
    file_format  = "raw"
    size         = each.value.disk_gb
    iothread     = true   # One I/O thread per disk — better performance
    discard      = "on"   # TRIM support for SSDs/thin-provisioned storage
    ssd          = true
  }

  boot_order = ["scsi0"]

  operating_system {
    type = "l26"  # Linux 2.6+ kernel
  }

  # Static IP config — Talos reads this via the nocloud datasource
  # This is how Terraform tells each VM its IP without SSH or cloud-init agents
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

  # Ignore disk changes after creation (e.g. Talos writes to disk at runtime)
  # Also ignore vm_state so Terraform doesn't try to force-stop running VMs
  lifecycle {
    ignore_changes = [
      disk,
      vm_state,
    ]
  }
}
