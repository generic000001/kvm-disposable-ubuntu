# kvm-disposable-ubuntu

Provision one disposable Ubuntu virtual machine locally with KVM/QEMU, libvirt,
Terraform, and cloud-init, while keeping the host-tooling lifecycle separate
from the everyday VM lifecycle.

This repository is designed for a technically proficient solo developer on an
Ubuntu workstation who wants a reproducible, reversible, auditable local VM lab
that can be prepared online and then operated offline within clearly defined
limits.

## Supported environment

- Ubuntu host: tested for repository generation on Ubuntu 26.04.1 LTS
  (`resolute`)
- host architecture: `x86_64`
- virtualisation model: Intel VT-x or AMD-V with `/dev/kvm`
- libvirt connection: `qemu:///system`
- guest network: libvirt default NAT network
- Terraform provider pin: exact version `dmacvicar/libvirt` `0.9.9`
- default guest image: official Ubuntu 26.04 LTS cloud image for `amd64`

## Architecture diagram

```text
Ubuntu 26.04 host
├── bootstrap.sh
│   ├── KVM/QEMU packages
│   ├── libvirt services and groups
│   ├── Terraform from HashiCorp APT
│   └── installation manifest
├── images/
│   └── verified Ubuntu source image cache
├── .cache/terraform/
│   └── optional offline provider mirror
├── /var/lib/libvirt/images/
│   └── kvm-disposable-ubuntu/ (default active disk location)
└── terraform/
    ├── libvirt pool definition
    ├── copied base image volume
    ├── copy-on-write overlay disk
    ├── cloud-init seed ISO
    └── disposable Ubuntu VM
        ├── normal user with SSH key
        ├── Docker Engine from Ubuntu packages
        ├── Docker Compose support
        └── optional qemu-guest-agent
```

## Component responsibilities

| Component | Responsibility |
| --- | --- |
| KVM | Hardware-assisted virtualisation on the host CPU |
| QEMU | The machine emulator and hypervisor userspace |
| libvirt | Host-side VM lifecycle, networking, storage, and permissions layer |
| Terraform | Declarative provisioning of the libvirt pool, volumes, and domain |
| cloud-init | First-boot guest customisation inside the VM |
| Docker | Application container runtime inside the guest |

## What each technology does

### KVM

KVM is the Linux kernel facility that turns the host into a hardware-assisted
hypervisor when the CPU and firmware expose VT-x or AMD-V.

### QEMU

QEMU provides the guest machine definition and userspace emulation layer. With
KVM acceleration enabled, it uses the kernel for fast CPU virtualisation rather
than pure emulation.

### libvirt

libvirt is the management API and tooling layer that coordinates domains,
networks, storage pools, permissions, and service activation. It is the stable
interface used by `virsh`, GUI tools, and the Terraform provider.

### Terraform

Terraform manages the libvirt resources declaratively and keeps the desired VM
lifecycle separate from the host bootstrap lifecycle.

### cloud-init

cloud-init applies the guest configuration on first boot: hostname, user
creation, SSH key injection, optional Docker installation, timezone, locale,
and optional guest-agent installation.

### Docker

Docker runs *inside the guest*, not on the host as part of the bootstrap. This
keeps container workloads disposable with the VM and avoids coupling them to the
host workstation.

### Why libvirt is not Kubernetes

libvirt manages virtual machines and their host integration. It does not provide
container orchestration, service scheduling, rolling deployments, or a cluster
control plane. It is a local virtualisation management layer, not an
application orchestration platform.

## Lifecycle split

### Everyday infrastructure lifecycle

These targets create, destroy, and recreate the disposable VM only:

```bash
make create
make destroy
make adopt
make destroy-existing
make rebuild
make status
make ssh
```

### Host tooling lifecycle

These targets manage workstation tooling and caches:

```bash
make bootstrap
make prepare-offline
make remove-host-tools
```

Destroying the VM does **not** uninstall KVM, libvirt, or Terraform.

### Existing deployment ownership

`make create` refuses to proceed when any of the fixed deployment resources
(the pool, domain, or managed volumes) already exists in libvirt but is not
fully represented in the current Terraform state. This prevents Terraform
from silently replacing or destroying resources created by another state.

Use `make status` to see the ownership diagnostics. Choose one explicit
recovery path:

```bash
make adopt            # import the complete existing deployment into this state
make destroy-existing # permanently remove it after an interactive confirmation
```

`make adopt` requires the complete fixed deployment to exist and imports it
without deleting resources; review `make plan` before applying. The
`destroy-existing` target never removes a pool containing non-deployment
volumes and does not modify Terraform state. Do not use either target unless
you have confirmed that the resources belong to this checkout.

## Host bootstrap instructions

`bootstrap.sh` is idempotent and installs only missing host packages. It:

1. verifies the host is Ubuntu on `x86_64`;
2. checks KVM capability and `/dev/kvm`;
3. installs KVM/QEMU, libvirt, `virt-install`, cloud-image tooling, and support
   utilities;
4. configures HashiCorp's signed APT repository without `apt-key`;
5. installs Terraform;
6. adds the invoking user to the `kvm` and `libvirt` groups if required;
7. enables the supported libvirt sockets or service;
8. ensures the default NAT network exists and autostarts;
9. records changes in a local installation manifest.

Run:

```bash
make bootstrap
```

If group membership changes, the script validates libvirt with `sudo` for the
current run and records that a session refresh is required. Sign out and back in
before expecting passwordless libvirt access in later commands.

## Online preparation instructions

Run:

```bash
make download-image
make verify-image
make prepare-offline
```

This downloads the official Ubuntu 26.04 cloud image into `images/`, downloads
`SHA256SUMS` and `SHA256SUMS.gpg`, authenticates the checksum manifest with the
Ubuntu cloud-image signing key fingerprint published by Canonical
(`D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81`), verifies the image checksum, and
mirrors the pinned Terraform provider into `.cache/terraform/provider-mirror/`.

The source URL is on the **released** channel, not the `daily` or `current`
channel, but the filename is still not immutable by content address. The local
metadata file records the release directory stamp and HTTP metadata so you can
audit which released build was cached.

## Image-cache design

The canonical guest image cache lives in `images/`. Terraform copies that image
into its own managed libvirt pool before it creates the copy-on-write overlay.
By default that pool lives at `/var/lib/libvirt/images/kvm-disposable-ubuntu`,
resolved with `pathexpand()` and `abspath()`, so active libvirt volumes do not
sit on the repository's `fuseblk` mount or under your private home directory.

That design means:

- `terraform apply` does not contact Ubuntu image servers;
- normal `terraform destroy` removes only Terraform-managed pool artefacts;
- the canonical cache survives rebuilds until you explicitly purge it.
- the disposable guest disk is copy-on-write relative to the **managed base
  copy**, not directly relative to the canonical cache file.

This is intentionally conservative for `qemu:///system`: the canonical image in
your repository remains outside Terraform ownership, while the libvirt-managed
copy sits in a storage location that libvirt and QEMU can own consistently.

## Why images are not committed to Git

Cloud images, provider mirrors, and offline bundles are large binary artefacts.
Keeping them out of normal Git history keeps the repository auditable, small,
and safe to clone repeatedly.

## Offline-mode explanation

This repository implements two explicit modes.

### 1. Image-cached mode (default)

After `make prepare-offline`:

- the Ubuntu source image is local;
- the checksum manifest signature has been authenticated;
- the libvirt provider binary can be mirrored locally;
- Terraform can be initialised and planned offline with `OFFLINE=1`;
- VM creation remains dependent on guest package availability if cloud-init must
  install Docker or the guest agent from Ubuntu repositories.

### 2. Fully prepared mode

In this mode you provide a local golden image that already contains Docker,
Docker Compose support, and any required guest packages. Then set:

```hcl
ubuntu_image_path        = "../images/ubuntu-26.04-docker-golden-amd64.qcow2"
install_docker           = false
install_qemu_guest_agent = false
```

That is the reliable way to make guest package installation independent of the
internet. `make offline-check MODE=fully-prepared` will only pass when the
configuration points at a golden image path and guest package installation is
disabled, but it still does not inspect the qcow2 contents directly.

## Exact definition of “offline” in this repository

“Offline” means that after `make prepare-offline` succeeds, the following can be
done without internet access **provided the guest does not need to install new
packages at boot**:

- `terraform init` with `OFFLINE=1`
- `terraform validate` with `OFFLINE=1`
- `terraform plan` with `OFFLINE=1`
- `terraform apply` with `OFFLINE=1`
- guest boot
- `terraform destroy`

In the default image-cached mode, Docker availability inside the guest may still
need internet access during first boot because the guest packages come from the
guest's configured Ubuntu repositories.

## Golden-image option

`packer/README.md` explains the recommended golden-image approach. Packer is not
mandatory for the simple path because it would add a second host image-build
toolchain, but fully prepared mode should use a controlled golden image.

## VM creation workflow

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
make init
make validate
make plan
make create
```

Use `make OFFLINE=1 init` and `make OFFLINE=1 plan` after `make prepare-offline`
if you want Terraform to use the mirrored provider only.

`make create` starts the VM by default so that cloud-init can run, the guest
can acquire a DHCP lease, and `make ip`/`make ssh` can be used immediately
after boot. To intentionally define the VM without starting it, set
`start_vm = false` in `terraform/terraform.tfvars` or pass
`-var='start_vm=false'` to Terraform.

## SSH workflow

```bash
make status
make ip
make ssh
```

`make cloud-init-status` waits for or prints `cloud-init` status from inside the
VM over SSH.

## VM destruction workflow

```bash
make destroy
```

This removes only Terraform-managed pool, volume, cloud-init, and domain
resources. The default managed pool directory remains
`/var/lib/libvirt/images/kvm-disposable-ubuntu` until you explicitly remove it.

## VM rebuild workflow

```bash
make rebuild
```

This prompts before destruction and recreation.

`make clean` removes only transient local working artefacts such as
`.terraform/`, temporary plans, and `.tmp/`. It does **not** remove Terraform
state and does **not** remove the managed libvirt pool data under the resolved
`libvirt_pool_path` (default `/var/lib/libvirt/images/kvm-disposable-ubuntu`).

## Complete host-tool removal workflow

```bash
make remove-host-tools
```

The removal script is conservative and interactive. It consults the local
installation manifest, refuses to silently delete Terraform state while managed
resources may still exist, and offers separate choices for caches, images, APT
sources, keyrings, groups, recorded packages, and the recorded Terraform pool
directory when it is empty and matches the default managed libvirt pool path.

## Terraform state explanation

Terraform state records the mapping between the declared resources and the
actual libvirt resources. It can also contain resource identifiers, host paths,
and other operational metadata. Treat it as operationally sensitive and do not
publish it casually.

## Terraform provider lock file explanation

`terraform/.terraform.lock.hcl` is generated locally by a real
`terraform init`. This repository does **not** treat a hand-written lock file as
authoritative. The lock file pins the provider version and known archive hashes,
but it is not the provider binary itself.

## Provider offline-mirror explanation

The provider mirror created by `make prepare-offline` stores the actual provider
archives used by offline `terraform init`. Without that mirror, the lock file
alone is not sufficient for offline initialisation.

## Security considerations

- membership in the `libvirt` group is powerful and effectively grants broad VM
  management capability on the host;
- membership in the guest `docker` group is effectively root-equivalent inside
  the guest;
- `qemu:///system` is intentionally used because it is the supported privileged
  libvirt system connection for local KVM management;
- SSH password authentication is disabled by default;
- no private SSH keys are generated or committed by this repository;
- cached images are verified against Ubuntu's published checksum manifest only
  after authenticating `SHA256SUMS.gpg` with the Ubuntu cloud-image signing key;
- Terraform state should be treated as operationally sensitive;
- importing untrusted VM images is risky and not recommended;
- running untrusted containers inside the guest still carries guest-side risk;
- default NAT networking is used instead of bridging to reduce accidental
  exposure;
- no guest ports are exposed on the host by default.

## Troubleshooting

### Host-side checks

```bash
kvm-ok
ls -l /dev/kvm
lsmod | grep -E 'kvm|kvm_intel|kvm_amd'
virsh -c qemu:///system uri
virsh -c qemu:///system net-list --all
virsh -c qemu:///system list --all
virsh -c qemu:///system pool-list --all
terraform -chdir=terraform validate
terraform -chdir=terraform init -backend=false
```

### Guest-side checks

Run these **inside the VM** after `make ssh`:

```bash
cloud-init status --long
sudo tail -n 100 /var/log/cloud-init.log /var/log/cloud-init-output.log
systemctl status docker
systemctl status qemu-guest-agent
docker version
```

### DHCP and SSH checks

```bash
make ip
virsh -c qemu:///system net-dhcp-leases default
ssh -vv ubuntu@<vm-ip>
```

## Recovery from partial bootstrap failure

Re-run `make bootstrap`. The script preserves correct existing configuration,
adds only missing packages, and re-checks groups, services, and the default
network.

## Recovery from failed cloud-init

Inspect:

```bash
make status
make ip
make cloud-init-status
```

Then log into the VM and review `/var/log/cloud-init.log`.

## Recovery from lost Terraform state

Do not delete state casually. If state is lost while resources still exist, you
will need a deliberate recovery or import workflow. This repository does not
automate that because accidental state deletion is riskier than a manual
recovery.

## Updating the Ubuntu image

```bash
make download-image ARGS=--force
make verify-image
```

Review the new metadata file in `images/` after refresh.

## Updating Terraform

Terraform is installed from HashiCorp's official APT repository. Upgrade it with
your normal `apt` workflow after reviewing available versions, for example:

```bash
sudo apt-get update
sudo apt-get install --only-upgrade terraform
```

To uninstall Terraform later, use `make remove-host-tools` and choose the
Terraform package removal option.

## Updating the libvirt provider

1. change the version constraint in `terraform/versions.tf`;
2. regenerate `terraform/.terraform.lock.hcl` with `terraform init`;
3. rerun `make prepare-offline` to refresh the provider mirror;
4. revalidate with `make check`.

## Docker image offline handling

Installing Docker does **not** make application container images available
offline. Prepare them separately, for example:

```bash
docker pull hello-world:latest
docker save hello-world:latest -o hello-world.tar
scp hello-world.tar ubuntu@<vm-ip>:
ssh ubuntu@<vm-ip> docker load -i hello-world.tar
```

Verify image identities with `docker image inspect --format '{{.Id}}'`.

The example Compose file in `examples/compose.yaml` uses `hello-world:latest`
and is not started automatically.

## Exporting and verifying an offline bundle

```bash
make export-offline-bundle
make verify-offline-bundle
```

The bundle is stored in `dist/` and excluded from Git history.

## Limitations

- the repository was generated on an unconfigured host without Terraform,
  libvirt, or QEMU installed, so runtime validation of provider syntax, lockfile
  generation, and VM provisioning could not be performed here;
- full guest offline package installation is **not** implemented in the default
  image-cached mode;
- `make offline-check MODE=fully-prepared` verifies configuration intent rather
  than inspecting the guest image contents directly.

## Commands to run next

```bash
cd kvm-disposable-ubuntu
make check
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
make bootstrap
make prepare-offline
make offline-check
make init
make validate
make plan
make create
make status
make ssh
make destroy
```
