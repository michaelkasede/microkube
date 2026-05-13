# microkube

Deploy a MicroK8s cluster on a Proxmox VE host with Terraform + Ansible.

- **Terraform** (`bpg/proxmox` provider) clones a cloud-init Ubuntu 24.04
  template into 3 VMs with static IPs.
- **Ansible** installs MicroK8s, joins the workers, and enables core addons
  (`dns`, `hostpath-storage`, `metallb`).

```text
Laptop  --(API token + SSH)--> Proxmox (10.10.10.10)
                                  |
                                  '---> mk-cp-1 (10.10.10.21)  master
                                        mk-w-1  (10.10.10.22)  worker
                                        mk-w-2  (10.10.10.23)  worker
```

## Node specifications

Each of the 3 VMs is provisioned with the following hardware:

| Resource     | Value         | Cluster total (3 VMs) |
| ------------ | ------------- | --------------------- |
| vCPU         | 2             | 6                     |
| Memory       | 4 GiB         | 12 GiB                |
| Disk         | 40 GiB        | 120 GiB               |
| Machine type | `q35`         | -                     |
| CPU type     | `host`        | -                     |
| BIOS         | SeaBIOS       | -                     |
| Guest OS     | Ubuntu 24.04  | -                     |

### Where to change the specs

All of these are exposed as Terraform variables in
[`terraform/variables.tf`](terraform/variables.tf):

| Variable          | Default  | What it controls                              |
| ----------------- | -------- | --------------------------------------------- |
| `vm_cpu_cores`    | `2`      | vCPU per node                                 |
| `vm_memory_mb`    | `4096`   | RAM per node (MiB)                            |
| `vm_disk_gb`      | `40`     | Root disk per node (GiB)                      |
| `vm_machine_type` | `"q35"`  | QEMU machine type                             |
| `vm_cpu_type`     | `"host"` | QEMU CPU type                                 |
| `nodes`           | 3 nodes  | Number of nodes, hostnames, roles, static IPs |

To override without touching version-controlled code, put them in
[`terraform/terraform.tfvars`](terraform/example.tfvars):

```hcl
vm_cpu_cores = 4
vm_memory_mb = 8192
vm_disk_gb   = 60
```

### Why these specs?

MicroK8s' [official minimum](https://microk8s.io/docs/install-alternatives)
is 4 GiB RAM and 20 GiB disk per node. The defaults here (4 GiB / 40 GiB)
are exactly the floor for RAM and a comfortable margin for disk (room for
container images, hostpath volumes, and `journald`). 2 vCPU is enough for
a control-plane node + a worker workload that's mostly Deployments,
DaemonSets, and a handful of stateful pods — typical homelab usage.

The whole cluster fits in **6 vCPU and 12 GiB RAM**, leaving comfortable
headroom on a typical homelab Proxmox box (e.g. 8C/16C CPU, 32-64 GiB RAM)
for the Proxmox host itself, other VMs, and LXC containers. CPU overcommit
on Proxmox is harmless here because Kubernetes control-plane traffic is
spiky and rarely saturates cores.

If you have spare capacity and want to run heavier workloads (e.g. CI
runners, Postgres, observability stacks), bump `vm_cpu_cores` to `4` and
`vm_memory_mb` to `8192`.

### Why machine type `q35`?

`q35` emulates a modern Intel Q35 Express chipset; the only alternative,
`i440fx`, emulates a 1996-era PIIX3 chipset. The relevant practical
differences for a Kubernetes homelab:

- **Native PCIe**, not PCI-with-bridge. Modern Linux guests (and the
  virtio drivers MicroK8s relies on) get a topology that matches real
  hardware. Fewer driver edge cases, cleaner `lspci` output.
- **Better hot-plug behavior** for NICs and disks, which matters when
  Terraform later resizes or replaces devices on a running VM.
- **Forward-compatible** with PCIe passthrough (GPUs, SR-IOV NICs) if you
  ever want to schedule GPU pods or do MetalLB BGP off a passthrough card.
- **Recommended by Proxmox** for any "modern Linux" guest. Ubuntu 24.04
  works on both, but `q35` is the documented happy path.

There is essentially zero downside on a single Proxmox host: `q35` doesn't
cost CPU, RAM, or disk versus `i440fx`. The only reason to stick with
`i440fx` is compatibility with very old guest OSes (Windows XP, etc.).

### Why CPU type `host`?

`host` is shorthand for "pass every CPU feature flag from the physical
processor straight through to the guest". The alternative (`kvm64`, the
QEMU default, or a baseline like `x86-64-v2-AES`) emulates a fixed,
lowest-common-denominator CPU model so VMs can be live-migrated between
hosts with different silicon.

For a single-node homelab Proxmox install, `host` is the right call:

- **No emulation overhead** for unsupported instructions. The guest sees
  AVX, AVX2, AES-NI, BMI2, SSE4.2, etc. directly. etcd, kube-apiserver,
  and containerd all benefit (TLS, hashing, image layer decompression,
  protobuf encoding).
- **Snap and Go binaries** in MicroK8s ship pre-compiled assuming modern
  x86_64 feature sets. Running them on a CPU model that hides those flags
  means slower code paths.
- **No migration cost** to pay, because there's nothing to migrate to.
  The trade-off you'd accept on a multi-node Proxmox cluster (where
  `host` can prevent live-migration to a different CPU family) simply
  doesn't apply here.

If you ever add a second Proxmox node and want live-migration, change
`vm_cpu_type` to `"x86-64-v2-AES"` (the most permissive safe baseline
for any post-2013 Intel/AMD CPU) and re-apply.

### Homelab-friendly defaults at a glance

| Decision      | Choice    | Why it's good for homelabs                                  |
| ------------- | --------- | ----------------------------------------------------------- |
| Cluster size  | 3 nodes   | Smallest setup that demonstrates master/worker separation   |
| vCPU / RAM    | 2 / 4 GiB | Hits MicroK8s minimums; fits comfortably on 16-32 GiB hosts |
| Disk          | 40 GiB    | Headroom for container images without bloating thin pools   |
| Machine       | `q35`     | Future-proof, identical performance, no driver gotchas      |
| CPU           | `host`    | Free performance on single-node Proxmox                     |
| BIOS          | SeaBIOS   | No EFI disk overhead; cloud images boot fine                |
| Full clone    | enabled   | VMs are independent of the template after creation          |
| Static IPs    | yes       | Predictable for kubeconfig, MetalLB, port-forwarding        |

## Repository layout

```text
microkube/
  cloud-config.yml.tftpl     cloud-init user-data, rendered per VM by Terraform
  scripts/
    bootstrap-proxmox.sh     one-shot setup script for the Proxmox host
  terraform/
    versions.tf, providers.tf, variables.tf
    main.tf                  cloud-init snippets + 3 VMs (cloned from VMID 103)
    outputs.tf               writes ansible/inventory/hosts.ini
    templates/hosts.ini.tftpl
    example.tfvars
  ansible/
    ansible.cfg, requirements.yml
    inventory/
      group_vars/all.yml     cluster-wide vars (microk8s channel, addons, etc.)
      hosts.ini              generated by terraform apply
    playbooks/site.yml
    roles/
      common/
      microk8s_install/
      microk8s_master/
      microk8s_worker/
```

## Prerequisites

On the **Proxmox host** (`10.10.10.10`):

- Proxmox VE 8.x or 9.x.
- The `snippets` content type enabled on the `local` datastore
  (Datacenter -> Storage -> local -> Content -> Snippets).
- Root SSH key auth from your laptop to the host (the `bpg/proxmox`
  provider uploads cloud-init snippets over SSH).

On **your laptop**:

- `terraform` >= 1.6
- `ansible` >= 2.15
- `kubectl` (to talk to the cluster after deploy)
- An SSH key whose public key matches the one in
  [`cloud-config.yml.tftpl`](cloud-config.yml.tftpl) (currently
  `michael@magnumx`). Replace the key inline if needed.

## 1. Bootstrap the Proxmox host (one-time)

Run [`scripts/bootstrap-proxmox.sh`](scripts/bootstrap-proxmox.sh) on the
Proxmox host as root. It is idempotent — safe to re-run.

```bash
scp scripts/bootstrap-proxmox.sh root@10.10.10.10:/root/
ssh root@10.10.10.10 bash /root/bootstrap-proxmox.sh
```

It will:

1. Create role `TerraformProv` with the minimum privileges the bpg provider
   needs.
2. Create user `terraform@pve` and grant the role on `/`.
3. Create API token `terraform@pve!provider` (privilege separation disabled)
   and **print the secret once** at the end.
4. Download the Ubuntu 24.04 cloud image and build a cloud-init template
   at VMID 103 (`ubuntu-2404-tmpl`) on `local-lvm`.

Copy the printed `pm_api_token = "..."` line into
`terraform/terraform.tfvars` (see next step). The secret cannot be
retrieved again; rotate with `pveum user token remove terraform@pve provider`
and re-run the script.

## 2. Configure Terraform variables

```bash
cd terraform
cp example.tfvars terraform.tfvars
# Paste the pm_api_token line from the bootstrap script output
$EDITOR terraform.tfvars
```

Most defaults match the locked-in homelab parameters (node `pve`,
datastore `local-lvm`, bridge `vmbr0`, gateway `10.10.10.1`, 3 nodes at
`10.10.10.21-23`). Override any of them in `terraform.tfvars`.

## 3. Provision the VMs

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This clones template 103 three times, applies a per-VM cloud-init snippet
(injecting the hostname), boots the VMs, and writes
`ansible/inventory/hosts.ini`.

## 4. Install MicroK8s with Ansible

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml
```

The playbook:

1. Waits for SSH and cloud-init to finish on all nodes.
2. Applies the `common` role (hostname, swap off, kernel modules, sysctl).
3. Installs the MicroK8s snap on every node.
4. Enables `dns` and `hostpath-storage` on the master.
5. Enables `metallb` with the range `10.10.10.200-10.10.10.220`.
6. Generates a join token on the master and joins both workers.

## 5. Get kubectl access

```bash
ssh foobar@10.10.10.21 'sudo microk8s config' > ~/.kube/config
kubectl get nodes
```

You should see all three nodes `Ready`.

## Tear-down

```bash
cd terraform
terraform destroy
```

The bootstrap script's effects (terraform user, API token, role,
template 103) persist on the Proxmox host and do not need to be
redone next time.

## Customising

- **More / fewer nodes, different IPs**: edit the `nodes` map in
  [`terraform/variables.tf`](terraform/variables.tf) (or override it via
  `terraform.tfvars`).
- **Different MicroK8s channel or addons**: edit
  [`ansible/inventory/group_vars/all.yml`](ansible/inventory/group_vars/all.yml).
- **Cloud-init changes** (extra packages, different user, etc.): edit
  [`cloud-config.yml.tftpl`](cloud-config.yml.tftpl). The
  `${hostname}` placeholder is the only Terraform-rendered field.
