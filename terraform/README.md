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
normalizations. The network interface `source.network.port_id` is a
libvirt-generated runtime identifier rather than configuration; its exact
nested path is ignored because it can change when the domain is redefined.
Other device attributes remain managed. Pool-path, volume-permission,
backing-volume, and explicit replacement triggers remain active for normal
creation and intentional replacement.

## Adoption runtime metadata

The following comparison is representative of the adoption state and a
subsequent refresh. The configured values are omitted because Terraform only
declares the device targets and network name; libvirt supplies these runtime
metadata fields after the domain is defined.

| Attribute | Configured? | Import value | Post-apply value | Runtime metadata? |
| --- | --- | --- | --- | --- |
| `devices.consoles[0].source.pty.path` | No | `/dev/pts/0` | `/dev/pts/1` | Yes |
| `devices.consoles[0].tty` | No | `/dev/pts/0` | `/dev/pts/1` | Yes |
| `devices.serials[0].source.pty.path` | No | `/dev/pts/0` | `/dev/pts/1` | Yes |
| `devices.channels[0].source.pty.path` | No | `/dev/pts/1` | `/dev/pts/2` | Yes |
| `devices.interfaces[0].source.network.port_id` | No | `6d44f700-e5da-467f-a03c-7e3870351a8a` | `a9941685-2de1-463b-8da7-13796208d551` | Yes |

The existing `devices` normalization also suppresses provider-added libvirt
XML defaults needed for an imported domain to remain stable. The five paths above are the additional runtime leaves that must be explicitly
normalized; imported `resource` and `sec_label` are likewise provider-only
domain metadata. Pool, volume, domain identity, replacement triggers, and
non-device drift remain visible to Terraform.

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
