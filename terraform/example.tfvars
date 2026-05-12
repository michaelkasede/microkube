# Copy this file to terraform.tfvars and fill in the API token from
# scripts/bootstrap-proxmox.sh. terraform.tfvars is gitignored.

# Paste the line printed by bootstrap-proxmox.sh here:
pm_api_token = "terraform@pve!provider=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Override any defaults from variables.tf below if needed, e.g.
# pm_endpoint     = "https://10.10.10.10:8006/"
# pm_node_name    = "pve"
# pm_ssh_username = "root"
# vm_datastore    = "local-lvm"
# default_gateway = "10.10.10.1"
# dns_servers     = ["10.10.10.1"]
# vm_machine_type = "q35"
# vm_cpu_type     = "host"
