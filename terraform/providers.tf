terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.75"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.7"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# ── pve1: Intel NUC i3-1115G4 / 64 GB RAM ────────────────────────────
# Main host — runs all 3 control planes + worker-1
provider "proxmox" {
  alias    = "pve1"
  endpoint = var.pve1_endpoint
  insecure = true # self-signed cert — fine for homelab

  ssh {
    agent    = true
    username = "root"
  }
}

# ── pve2: Intel N100 / 16 GB RAM ─────────────────────────────────────
# ⚠️  OPNsense (your ISP gateway) lives here!
# worker-2 RAM is fixed/capped in vms.tf — OPNsense must not starve
provider "proxmox" {
  alias    = "pve2"
  endpoint = var.pve2_endpoint
  insecure = true

  ssh {
    agent    = true
    username = "root"
  }
}
