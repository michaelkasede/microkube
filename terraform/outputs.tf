###############################################################################
# Strip the CIDR suffix from each node's address so it's usable as ansible_host.
###############################################################################

locals {
  node_ips = {
    for name, cfg in var.nodes :
    name => split("/", cfg.ipv4_cidr)[0]
  }

  inventory_nodes = {
    for name, cfg in var.nodes :
    name => {
      ip   = local.node_ips[name]
      role = cfg.role
    }
  }

  inventory_rendered = templatefile("${path.module}/templates/hosts.ini.tftpl", {
    nodes    = local.inventory_nodes
    ssh_user = "foobar"
  })
}

###############################################################################
# Write the inventory file directly into ../ansible/inventory/hosts.ini
# so `ansible-playbook` can pick it up without an extra step.
###############################################################################

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.ini"
  content         = local.inventory_rendered
  file_permission = "0644"
}

###############################################################################
# Useful outputs.
###############################################################################

output "node_ips" {
  description = "Map of node name to IPv4 address (no CIDR suffix)."
  value       = local.node_ips
}

output "master_ip" {
  description = "IPv4 address of the (first) master node."
  value = one([
    for name, cfg in var.nodes :
    local.node_ips[name] if cfg.role == "master"
  ])
}

output "ansible_inventory_path" {
  description = "Path to the generated Ansible inventory file."
  value       = local_file.ansible_inventory.filename
}

output "ansible_inventory" {
  description = "Rendered Ansible inventory contents."
  value       = local.inventory_rendered
}
