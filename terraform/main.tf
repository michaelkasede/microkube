###############################################################################
# Cloud-init snippets — one per VM so we can inject the hostname.
# The snippet is uploaded to the Proxmox `snippets` content datastore
# (default: `local`) via SSH/SCP by the provider.
###############################################################################

resource "proxmox_virtual_environment_file" "cloud_config" {
  for_each = var.nodes

  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.pm_node_name

  source_raw {
    data = templatefile("${path.module}/../cloud-config.yml.tftpl", {
      hostname = each.key
    })
    file_name = "microkube-${each.key}.yaml"
  }
}

###############################################################################
# Cluster VMs — clone the cloud-init template (VMID 103) once per node.
###############################################################################

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name        = each.key
  description = "${var.cluster_name} ${each.value.role} (managed by Terraform)"
  tags        = [var.cluster_name, each.value.role]
  node_name   = var.pm_node_name
  machine     = var.vm_machine_type

  # Clone the template built by scripts/bootstrap-proxmox.sh.
  clone {
    vm_id = var.template_vmid
    full  = true
  }

  # qemu-guest-agent is installed via cloud-init in the template, so
  # enabling this lets Terraform pick up the VM IP if you ever want it.
  agent {
    enabled = true
  }

  # Allow `terraform destroy` to power off running VMs cleanly.
  stop_on_destroy = true

  cpu {
    cores = var.vm_cpu_cores
    type  = var.vm_cpu_type
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  # Resize the cloned disk to the desired size. The template's scsi0 disk
  # is on `local-lvm`; we keep it there and just grow it.
  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = var.vm_disk_gb
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  initialization {
    datastore_id = var.vm_datastore

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = each.value.ipv4_cidr
        gateway = var.default_gateway
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_config[each.key].id
  }

  # Cloud-init applies the hostname/users on first boot; let it finish before
  # Terraform considers the resource ready so Ansible can connect immediately.
  lifecycle {
    ignore_changes = [
      # The cloned scsi0 will be reported with the template's original size
      # on import-style refreshes; ignoring size churn here is safe because
      # we set it explicitly above.
      initialization[0].user_account,
    ]
  }
}
