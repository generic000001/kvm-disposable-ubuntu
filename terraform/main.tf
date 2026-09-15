resource "libvirt_pool" "vm_pool" {
  name = local.pool_name
  type = "dir"

  target = {
    path = local.pool_path
  }

  lifecycle {
    # libvirt provider 0.9.9 imports directory pools without refreshing the
    # target block. Pools cannot be updated, so avoid a perpetual update after
    # adoption while retaining the target for newly created pools.
    ignore_changes = [target]
  }
}

resource "libvirt_volume" "base_image" {
  for_each = local.managed_volume_permission_instances

  name = local.base_volume_name
  pool = libvirt_pool.vm_pool.name

  lifecycle {
    replace_triggered_by = [libvirt_pool.vm_pool.target.path]
    # Imports omit the create source and refresh provider-computed volume
    # metadata. The permission revision and pool path still force replacement.
    ignore_changes = [
      allocation,
      allocation_unit,
      capacity,
      capacity_unit,
      create,
      physical_unit,
      target,
      type,
    ]
    precondition {
      condition     = local.libvirt_volume_owner_uid != "" && local.libvirt_volume_group_gid != ""
      error_message = "Libvirt runtime UID/GID not recorded in ~/.local/state/kvm-disposable-ubuntu/install-manifest.json. Run bootstrap.sh or scripts/record-libvirt-runtime-identity.sh."
    }
  }

  target = {
    format = {
      type = "qcow2"
    }
    permissions = each.value
  }

  create = {
    content = {
      # This imports a managed copy into libvirt-owned storage. The canonical
      # cache in ../images/ remains outside Terraform ownership.
      url = local.image_path
    }
  }
}

resource "libvirt_volume" "vm_disk" {
  for_each = local.managed_volume_permission_instances

  name     = local.guest_volume_name
  pool     = libvirt_pool.vm_pool.name
  capacity = local.vm_disk_bytes

  lifecycle {
    replace_triggered_by = [
      libvirt_pool.vm_pool.target.path,
      libvirt_volume.base_image,
    ]
    # The importer adds backing-store and target metadata that is not part of
    # the declared overlay configuration. Base-volume changes still replace it.
    ignore_changes = [
      allocation,
      allocation_unit,
      capacity_unit,
      physical_unit,
      backing_store,
      target,
      type,
    ]
    precondition {
      condition     = local.libvirt_volume_owner_uid != "" && local.libvirt_volume_group_gid != ""
      error_message = "Libvirt runtime UID/GID not recorded in ~/.local/state/kvm-disposable-ubuntu/install-manifest.json. Run bootstrap.sh or scripts/record-libvirt-runtime-identity.sh."
    }
  }

  target = {
    format = {
      type = "qcow2"
    }
    permissions = each.value
  }

  backing_store = {
    # The guest disk is a qcow2 overlay backed by the managed base copy above.
    path = libvirt_volume.base_image[local.managed_volume_permissions_revision].path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "vm_seed" {
  name = local.cloudinit_name

  user_data = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
    hostname                 = var.vm_name
    username                 = var.username
    ssh_public_key           = local.ssh_public_key
    locale                   = var.locale
    timezone                 = var.timezone
    install_docker           = var.install_docker
    install_qemu_guest_agent = var.install_qemu_guest_agent
  })

  meta_data = templatefile("${path.module}/cloud-init/meta-data.yaml.tftpl", {
    hostname = var.vm_name
  })

  network_config = templatefile("${path.module}/cloud-init/network-config.yaml.tftpl", {})
}

resource "libvirt_volume" "vm_seed_iso" {
  for_each = local.managed_volume_permission_instances

  name = local.seed_volume_name
  pool = libvirt_pool.vm_pool.name

  lifecycle {
    replace_triggered_by = [libvirt_pool.vm_pool.target.path]
    # Imports omit the create source and refresh provider-computed volume
    # metadata. The permission revision and pool path still force replacement.
    ignore_changes = [
      allocation,
      allocation_unit,
      capacity,
      capacity_unit,
      create,
      physical_unit,
      target,
      type,
    ]
    precondition {
      condition     = local.libvirt_volume_owner_uid != "" && local.libvirt_volume_group_gid != ""
      error_message = "Libvirt runtime UID/GID not recorded in ~/.local/state/kvm-disposable-ubuntu/install-manifest.json. Run bootstrap.sh or scripts/record-libvirt-runtime-identity.sh."
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.vm_seed.path
    }
  }

  target = {
    permissions = each.value
  }
}

resource "libvirt_domain" "vm" {
  name        = var.vm_name
  title       = var.vm_name
  description = local.description
  memory      = var.vm_memory_mb
  memory_unit = "MiB"
  vcpu        = var.vm_vcpus
  type        = "kvm"
  autostart   = false
  running     = var.start_vm
  on_reboot   = "restart"
  on_crash    = "destroy"
  on_poweroff = "destroy"

  lifecycle {
    replace_triggered_by = [
      libvirt_volume.vm_disk,
      libvirt_volume.vm_seed_iso,
    ]
    # Import refreshes libvirt XML defaults and unit conversions that are
    # semantically equivalent to this configuration.
    ignore_changes = [
      clock,
      cpu,
      current_memory,
      current_memory_unit,
      devices,
      memory,
      memory_unit,
      os,
      vcpu_placement,
    ]
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [
      {
        dev = "hd"
      }
    ]
  }

  devices = {
    disks = [
      {
        source = {
          file = {
            file = libvirt_volume.vm_disk[local.volume_permissions_revision].path
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        driver = {
          type = "qcow2"
        }
      },
      {
        device = "cdrom"
        source = {
          file = {
            file = libvirt_volume.vm_seed_iso[local.volume_permissions_revision].path
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      }
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.libvirt_network_name
          }
        }
      }
    ]

    rngs = [
      {
        model = "virtio"
        backend = {
          random = "/dev/urandom"
        }
      }
    ]

    serials = [
      {
        target = {
          port = 0
          type = "isa-serial"
        }
      }
    ]

    consoles = [
      {
        target = {
          port = 0
          type = "serial"
        }
      }
    ]

    channels = var.install_qemu_guest_agent ? [
      {
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      }
    ] : []
  }
}

data "libvirt_domain_interface_addresses" "vm" {
  domain = libvirt_domain.vm.name
  source = var.install_qemu_guest_agent ? "any" : "lease"
}
