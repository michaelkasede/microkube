provider "proxmox" {
  endpoint  = var.pm_endpoint
  api_token = var.pm_api_token
  insecure  = var.pm_tls_insecure

  # The bpg provider also needs SSH access to the Proxmox host for
  # snippet uploads and disk imports.
  ssh {
    agent    = true
    username = var.pm_ssh_username

    node {
      name    = var.pm_node_name
      address = var.pm_ssh_host
    }
  }
}
