# ── Proxmox endpoints ─────────────────────────────────────────────────

variable "pve1_endpoint" {
  description = "HTTPS URL for pve1 Proxmox API (e.g. https://192.168.1.10:8006)"
  type        = string
}

variable "pve2_endpoint" {
  description = "HTTPS URL for pve2 Proxmox API (e.g. https://192.168.1.11:8006)"
  type        = string
}

# ── Network ───────────────────────────────────────────────────────────

variable "cluster_vip" {
  description = "Floating VIP for the Kubernetes API server (kube-apiserver on :6443). Must be an unused static IP on your LAN, outside DHCP range."
  type        = string
}

variable "cluster_gateway" {
  description = "Default LAN gateway — your OPNsense LAN interface IP (lives on pve2)"
  type        = string
}

variable "cluster_dns" {
  description = "DNS server for all K8s nodes — your Pi-hole IP on rpi1"
  type        = string
}

variable "cluster_subnet" {
  description = "Subnet prefix length (e.g. 24 means /24 = 255.255.255.0)"
  type        = number
  default     = 24
}

# ── Cluster ───────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name for the Talos/Kubernetes cluster"
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos Linux version — check https://github.com/siderolabs/talos/releases"
  type        = string
  default     = "v1.9.5"
}

# ── Storage ───────────────────────────────────────────────────────────

variable "pve1_datastore" {
  description = "Proxmox storage pool on pve1 for VM disks (e.g. local-lvm, local-zfs)"
  type        = string
  default     = "local-lvm"
}

variable "pve2_datastore" {
  description = "Proxmox storage pool on pve2 for VM disks"
  type        = string
  default     = "local-lvm"
}

# ── Node IPs (must be outside your DHCP range!) ───────────────────────

variable "cp_ips" {
  description = "Static IPs for the 3 control plane nodes [cp-1, cp-2, cp-3]"
  type        = list(string)
  default     = ["192.168.1.101", "192.168.1.102", "192.168.1.103"]
}

variable "worker_pve1_ip" {
  description = "Static IP for talos-worker-1 (on pve1)"
  type        = string
  default     = "192.168.1.111"
}

variable "worker_pve2_ip" {
  description = "Static IP for talos-worker-2 (on pve2 — the OPNsense host, be careful!)"
  type        = string
  default     = "192.168.1.112"
}
