###############################################################################
# Proxmox connection
###############################################################################

variable "pm_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://10.10.10.10:8006/"
  type        = string
  default     = "https://10.10.10.10:8006/"
}

variable "pm_api_token" {
  description = "Proxmox API token in the form 'user@realm!tokenid=secret'."
  type        = string
  sensitive   = true
}

variable "pm_tls_insecure" {
  description = "Skip TLS verification for the Proxmox API (typical for homelab with self-signed cert)."
  type        = bool
  default     = true
}

variable "pm_ssh_host" {
  description = "Address used by the provider's SSH block to reach the Proxmox host (snippet uploads, disk imports)."
  type        = string
  default     = "10.10.10.10"
}

variable "pm_ssh_username" {
  description = "SSH user on the Proxmox host. Must have key-based auth set up from the machine running Terraform."
  type        = string
  default     = "root"
}

variable "pm_node_name" {
  description = "Proxmox node name where VMs are created."
  type        = string
  default     = "pve"
}

###############################################################################
# Storage / template
###############################################################################

variable "vm_datastore" {
  description = "Proxmox datastore for VM disks."
  type        = string
  default     = "local-lvm"
}

variable "snippets_datastore" {
  description = "Proxmox datastore that has the 'snippets' content type enabled (for cloud-init user-data)."
  type        = string
  default     = "local"
}

variable "template_vmid" {
  description = "VMID of the cloud-init-ready template to clone (created by scripts/bootstrap-proxmox.sh)."
  type        = number
  default     = 103
}

variable "network_bridge" {
  description = "Proxmox bridge for VM NICs."
  type        = string
  default     = "vmbr0"
}

###############################################################################
# Cluster topology
###############################################################################

variable "cluster_name" {
  description = "Logical cluster name (used as a prefix for VM tags)."
  type        = string
  default     = "microkube"
}

variable "default_gateway" {
  description = "IPv4 default gateway for the cluster VMs."
  type        = string
  default     = "10.10.10.1"
}

variable "dns_servers" {
  description = "DNS servers for the cluster VMs."
  type        = list(string)
  default     = ["10.10.10.1"]
}

variable "vm_machine_type" {
  description = "QEMU machine type for cluster VMs."
  type        = string
  default     = "q35"
}

variable "vm_cpu_type" {
  description = "QEMU CPU type. 'host' gives best performance on single-node Proxmox; switch to 'x86-64-v2-AES' if you ever migrate VMs between dissimilar hosts."
  type        = string
  default     = "host"
}

variable "vm_cpu_cores" {
  description = "vCPU cores per cluster VM."
  type        = number
  default     = 2
}

variable "vm_memory_mb" {
  description = "Memory (MiB) per cluster VM."
  type        = number
  default     = 4096
}

variable "vm_disk_gb" {
  description = "Disk size (GiB) per cluster VM (resized after cloning)."
  type        = number
  default     = 40
}

# Map of all cluster nodes. Keys are the short hostnames used by Terraform and
# Ansible inventory; values describe the role and static IP (CIDR).
variable "nodes" {
  description = "Map of cluster nodes: { name => { role, ipv4_cidr } }."
  type = map(object({
    role      = string # "master" or "worker"
    ipv4_cidr = string # e.g. "10.10.10.21/24"
  }))
  default = {
    "mk-cp-1" = { role = "master", ipv4_cidr = "10.10.10.21/24" }
    "mk-w-1"  = { role = "worker", ipv4_cidr = "10.10.10.22/24" }
    "mk-w-2"  = { role = "worker", ipv4_cidr = "10.10.10.23/24" }
  }
}
