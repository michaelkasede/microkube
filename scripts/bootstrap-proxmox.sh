#!/usr/bin/env bash
# bootstrap-proxmox.sh
#
# One-shot setup script for the Proxmox host that prepares everything
# the Terraform bpg/proxmox provider needs to manage VMs on this node.
#
# What it does (idempotent — safe to re-run):
#   1. Creates a custom role `TerraformProv` with the minimum privileges
#      the bpg/proxmox provider needs.
#   2. Creates the user `terraform@pve`.
#   3. Grants the role on `/` so the user can manage storage, VMs, snippets.
#   4. Creates an API token `terraform@pve!provider` with Privilege
#      Separation disabled so the token inherits the user's privileges.
#   5. Downloads the Ubuntu 24.04 cloud image and builds a cloud-init
#      VM template at VMID 103 (named `ubuntu-2404-tmpl`).
#   6. Prints the API token line to paste into terraform.tfvars.
#
# Usage (run on the Proxmox host as root):
#   scp scripts/bootstrap-proxmox.sh root@10.10.10.10:/root/
#   ssh root@10.10.10.10 bash /root/bootstrap-proxmox.sh
#
# Note: the snippets content type must already be enabled on the `local`
# datastore (Datacenter -> Storage -> local -> Content -> Snippets).
# This script does not touch storage configuration.

set -euo pipefail

# ---- Tunables ---------------------------------------------------------------
TF_USER="terraform@pve"
TF_ROLE="TerraformProv"
TF_TOKEN_NAME="provider"

TEMPLATE_VMID="${TEMPLATE_VMID:-103}"
TEMPLATE_NAME="${TEMPLATE_NAME:-ubuntu-mk8s-tmpl}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local-lvm}"
TEMPLATE_BRIDGE="${TEMPLATE_BRIDGE:-vmbr0}"
TEMPLATE_MEMORY="${TEMPLATE_MEMORY:-2048}"
TEMPLATE_CORES="${TEMPLATE_CORES:-2}"

CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
CLOUD_IMG_DIR="/var/lib/vz/images/qcow"
CLOUD_IMG_FILE="${CLOUD_IMG_DIR}/noble-server-cloudimg-amd64.img"

# Minimum privileges required by the bpg/proxmox provider for VM lifecycle,
# disk import, cloud-init config, and snippet uploads.
TF_PRIVS=(
  "Datastore.Allocate"
  "Datastore.AllocateSpace"
  "Datastore.AllocateTemplate"
  "Datastore.Audit"
  "Pool.Allocate"
  "SDN.Use"
  "Sys.Audit"
  "Sys.Console"
  "Sys.Modify"
  "VM.Allocate"
  "VM.Audit"
  "VM.Clone"
  "VM.Config.CDROM"
  "VM.Config.Cloudinit"
  "VM.Config.CPU"
  "VM.Config.Disk"
  "VM.Config.HWType"
  "VM.Config.Memory"
  "VM.Config.Network"
  "VM.Config.Options"
  "VM.Migrate"
  "VM.Monitor"
  "VM.PowerMgmt"
  "User.Modify"
)

# ---- Helpers ----------------------------------------------------------------
log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Must be run as root on the Proxmox host."
  fi
}

require_pve() {
  command -v pveum >/dev/null 2>&1 || die "pveum not found — is this a Proxmox VE host?"
  command -v qm    >/dev/null 2>&1 || die "qm not found — is this a Proxmox VE host?"
  command -v pvesm >/dev/null 2>&1 || die "pvesm not found — is this a Proxmox VE host?"
}

check_snippets_enabled() {
  local content
  content="$(pvesm status -storage local 2>/dev/null | awk 'NR==2 {print}' || true)"
  if pvesh get /storage/local --output-format=json 2>/dev/null | grep -q '"snippets"'; then
    return 0
  fi
  if pvesh get /storage/local --output-format=json 2>/dev/null | grep -q '"content".*snippets'; then
    return 0
  fi
  warn "Could not confirm 'snippets' content type is enabled on storage 'local'."
  warn "If terraform apply fails to upload the cloud-init snippet, enable it in"
  warn "Datacenter -> Storage -> local -> Content -> Snippets, or run:"
  warn "  pvesm set local --content <existing>,snippets"
}

# ---- 1. Role ----------------------------------------------------------------
ensure_role() {
  local privs="${TF_PRIVS[*]}"
  if pveum role list --output-format=json 2>/dev/null | grep -q "\"roleid\":\"${TF_ROLE}\""; then
    log "Role '${TF_ROLE}' exists — updating privileges."
    pveum role modify "${TF_ROLE}" -privs "${privs}"
  else
    log "Creating role '${TF_ROLE}'."
    pveum role add "${TF_ROLE}" -privs "${privs}"
  fi
}

# ---- 2. User ----------------------------------------------------------------
ensure_user() {
  if pveum user list --output-format=json 2>/dev/null | grep -q "\"userid\":\"${TF_USER}\""; then
    log "User '${TF_USER}' already exists."
  else
    log "Creating user '${TF_USER}'."
    pveum user add "${TF_USER}" --comment "Terraform automation user"
  fi
}

# ---- 3. ACL -----------------------------------------------------------------
ensure_acl() {
  log "Granting role '${TF_ROLE}' to '${TF_USER}' on '/'."
  pveum acl modify / --users "${TF_USER}" --roles "${TF_ROLE}"
}

# ---- 4. API Token -----------------------------------------------------------
ensure_token() {
  local token_id="${TF_USER}!${TF_TOKEN_NAME}"
  local existing
  existing="$(pveum user token list "${TF_USER}" --output-format=json 2>/dev/null \
    | grep -o "\"tokenid\":\"${TF_TOKEN_NAME}\"" || true)"

  if [[ -n "${existing}" ]]; then
    warn "API token '${token_id}' already exists."
    warn "Its secret value cannot be retrieved again. To rotate it, run:"
    warn "  pveum user token remove ${TF_USER} ${TF_TOKEN_NAME}"
    warn "  bash $(basename "$0")"
    TOKEN_SECRET=""
    return 0
  fi

  log "Creating API token '${token_id}' (privsep=0)."
  local token_json
  token_json="$(pveum user token add "${TF_USER}" "${TF_TOKEN_NAME}" \
    --privsep 0 --output-format=json)"
  TOKEN_SECRET="$(printf '%s' "${token_json}" \
    | grep -oE '"value":"[^"]+"' | head -1 | sed -E 's/.*"value":"([^"]+)"/\1/')"

  if [[ -z "${TOKEN_SECRET}" ]]; then
    die "Failed to parse token secret from: ${token_json}"
  fi
}

# ---- 5. Cloud-init template -------------------------------------------------
ensure_template() {
  if qm status "${TEMPLATE_VMID}" >/dev/null 2>&1; then
    log "Template VMID ${TEMPLATE_VMID} already exists — destroying to rebuild."
    qm destroy "${TEMPLATE_VMID}" --purge --destroy-unreferenced-disks 1
  fi

  log "Downloading Ubuntu 24.04 cloud image (if needed)."
  mkdir -p "${CLOUD_IMG_DIR}"
  if [[ ! -f "${CLOUD_IMG_FILE}" ]]; then
    wget -q --show-progress -O "${CLOUD_IMG_FILE}.partial" "${CLOUD_IMG_URL}"
    mv "${CLOUD_IMG_FILE}.partial" "${CLOUD_IMG_FILE}"
  fi

  log "Creating VM ${TEMPLATE_VMID} (${TEMPLATE_NAME}) [machine=q35 cpu=host]."
  qm create "${TEMPLATE_VMID}" \
    --name    "${TEMPLATE_NAME}" \
    --memory  "${TEMPLATE_MEMORY}" \
    --cores   "${TEMPLATE_CORES}" \
    --cpu     host \
    --machine q35 \
    --net0    "virtio,bridge=${TEMPLATE_BRIDGE}" \
    --scsihw  virtio-scsi-pci \
    --ostype  l26 \
    --agent   enabled=1

  log "Importing cloud image as scsi0 on ${TEMPLATE_STORAGE}."
  qm set "${TEMPLATE_VMID}" \
    --scsi0 "${TEMPLATE_STORAGE}:0,import-from=${CLOUD_IMG_FILE}"

  log "Attaching cloud-init drive and serial console."
  qm set "${TEMPLATE_VMID}" \
    --ide2 "${TEMPLATE_STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0

  log "Converting VM ${TEMPLATE_VMID} to a template."
  qm template "${TEMPLATE_VMID}"
}

# ---- 6. Summary -------------------------------------------------------------
print_summary() {
  echo
  echo "================================================================"
  echo "  Proxmox bootstrap complete"
  echo "================================================================"
  echo "  Node          : $(hostname)"
  echo "  User          : ${TF_USER}"
  echo "  Role          : ${TF_ROLE}"
  echo "  Template VMID : ${TEMPLATE_VMID} (${TEMPLATE_NAME})"
  echo "  Storage       : ${TEMPLATE_STORAGE}"
  echo

  if [[ -n "${TOKEN_SECRET:-}" ]]; then
    echo "  ============ COPY INTO terraform/terraform.tfvars ============"
    echo "  pm_api_token = \"${TF_USER}!${TF_TOKEN_NAME}=${TOKEN_SECRET}\""
    echo "  =============================================================="
    echo
    echo "  This secret is shown ONCE. Save it now."
  else
    echo "  API token already existed; secret not re-displayed."
    echo "  Reuse the previously saved secret, or rotate with:"
    echo "    pveum user token remove ${TF_USER} ${TF_TOKEN_NAME}"
    echo "    bash $(basename "$0")"
  fi
  echo "================================================================"
}

# ---- Main -------------------------------------------------------------------
main() {
  require_root
  require_pve
  check_snippets_enabled

  ensure_role
  ensure_user
  ensure_acl
  ensure_token
  ensure_template

  print_summary
}

main "$@"
