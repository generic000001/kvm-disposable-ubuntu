# Terraform layout

This directory contains a single-purpose Terraform configuration for one
disposable Ubuntu VM managed through `qemu:///system`.

Key choices:

1. provider pin: exact version `dmacvicar/libvirt` `0.9.9`;
2. one managed libvirt directory pool under `terraform/.generated/pool`;
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
