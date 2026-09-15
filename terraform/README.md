# Terraform layout

This directory contains a single-purpose Terraform configuration for one
disposable Ubuntu VM managed through `qemu:///system`.

Key choices:

1. provider pin: exact version `dmacvicar/libvirt` `0.9.9`;
2. one managed libvirt directory pool on the standard libvirt images hierarchy,
   defaulting to `/var/lib/libvirt/images/kvm-disposable-ubuntu`;
3. one managed base-image copy inside that pool sourced from a verified local image;
4. one copy-on-write overlay disk for the disposable guest;
5. one cloud-init ISO generated from templates in `terraform/cloud-init/`.

The base image in `../images/` is the canonical cache. Terraform imports a copy
of that image into the managed libvirt pool so that destroying the VM removes
only Terraform-managed resources and not the canonical cache.

That also means the current implementation keeps **two** qcow2 base-image
artefacts locally:

1. the canonical cached image in `../images/`, which Terraform never owns;
2. a Terraform-managed copy inside the libvirt pool, which exists so the guest
   can use a libvirt-managed backing file under `qemu:///system`.

The pool path is configurable through `libvirt_pool_path`, and the Terraform
configuration resolves it with `abspath(pathexpand(...))` before passing it to
`libvirt_pool.target.path`. The default keeps active libvirt volumes off the
repository's `fuseblk` mount while remaining inside Ubuntu's standard
AppArmor-permitted libvirt storage hierarchy.

The pinned provider imports an existing directory pool by UUID but may refresh
its `target` block as null. Because libvirt storage pools cannot be updated,
the pool ignores changes to that provider-managed block after import; the
configured target is still used when Terraform creates a new pool.

The same provider also refreshes imported volumes without their declarative
create source and with computed allocation, target, and backing-store metadata.
Imported domains contain libvirt-generated XML defaults and unit
normalizations. The resource lifecycle ignores only those importer/computed
fields; pool-path, volume-permission, backing-volume, and explicit replacement
triggers remain active for normal creation and intentional replacement.

## Offline provider mirror

`make prepare-offline` populates `.cache/terraform/provider-mirror/` and writes
`.cache/terraform/terraformrc.offline.tfrc`.

Use:

```bash
make OFFLINE=1 init
make OFFLINE=1 validate
make OFFLINE=1 plan
```

`OFFLINE=1` forces Terraform to use the local filesystem mirror for the pinned
libvirt provider. The authoritative lock file is generated locally by
`terraform init` during `make prepare-offline`; the mirror stores the actual
provider binaries.
