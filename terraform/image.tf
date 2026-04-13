# ══════════════════════════════════════════════════════════════════════
# image.tf
# Posts the schematic to Talos Image Factory, gets back a unique ID,
# then downloads the pre-built raw disk image to BOTH Proxmox hosts.
# The image is a complete bootable disk — no installer needed.
# ══════════════════════════════════════════════════════════════════════

locals {
  schematic = file("${path.module}/../talos/image/schematic.yaml")
}

# POST the schematic YAML to Image Factory → get back a unique schematic ID
data "http" "schematic_id" {
  url          = "https://factory.talos.dev/schematics"
  method       = "POST"
  request_body = local.schematic

  request_headers = {
    Content-Type = "application/json"
  }
}

locals {
  schematic_id = jsondecode(data.http.schematic_id.response_body)["id"]

  # URL of the compressed raw disk image for the nocloud platform (Proxmox compatible)
  image_url = "https://factory.talos.dev/image/${local.schematic_id}/${var.talos_version}/nocloud-amd64.raw.gz"

  # Filename stored in each Proxmox node's ISO datastore
  # NOTE: Proxmox calls this storage "iso" but it can hold any file type
  image_name = "talos-${local.schematic_id}-${var.talos_version}-nocloud-amd64.img"
}

# ── Download to pve1 ──────────────────────────────────────────────────
# pve1 hosts: talos-cp-1, talos-cp-2, talos-cp-3, talos-worker-1
resource "proxmox_virtual_environment_download_file" "talos_image_pve1" {
  provider = proxmox.pve1

  node_name               = "pve1"
  content_type            = "iso"      # Proxmox's "iso" store — holds any file
  datastore_id            = "local"    # The shared file pool on pve1
  file_name               = local.image_name
  url                     = local.image_url
  decompression_algorithm = "gz"       # Proxmox decompresses the .gz in place
  overwrite               = false      # Don't re-download if already present
}

# ── Download to pve2 ──────────────────────────────────────────────────
# pve2 hosts: talos-worker-2
# ⚠️  This host also runs OPNsense — the image download is a one-time operation
resource "proxmox_virtual_environment_download_file" "talos_image_pve2" {
  provider = proxmox.pve2

  node_name               = "pve2"
  content_type            = "iso"
  datastore_id            = "local"
  file_name               = local.image_name
  url                     = local.image_url
  decompression_algorithm = "gz"
  overwrite               = false
}

# ── Helper map: provider alias → image file_id ───────────────────────
# Used in vms.tf to select the correct image per host
locals {
  image_file_ids = {
    pve1 = proxmox_virtual_environment_download_file.talos_image_pve1.id
    pve2 = proxmox_virtual_environment_download_file.talos_image_pve2.id
  }
}
