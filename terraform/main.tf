resource "libvirt_pool" "vm_pool" {
  name = local.pool_name
  type = "dir"

  target = {
    path = local.pool_path
  }
}

resource "libvirt_volume" "base_image" {
  name = local.base_volume_name
  pool = libvirt_pool.vm_pool.name

  target = {
    format = {
      type = "qcow2"
    }
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
  name     = local.guest_volume_name
  pool     = libvirt_pool.vm_pool.name
  capacity = local.vm_disk_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    # The guest disk is a qcow2 overlay backed by the managed base copy above.
    path = libvirt_volume.base_image.path
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
  name   = local.seed_volume_name
  pool   = libvirt_pool.vm_pool.name
  format = "raw"

  create = {
    content = {
      url = libvirt_cloudinit_disk.vm_seed.path
    }
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
  running     = true
  on_reboot   = "restart"
  on_crash    = "destroy"
  on_poweroff = "destroy"

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = ["hd"]
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.vm_disk.pool
            volume = libvirt_volume.vm_disk.name
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
          volume = {
            pool   = libvirt_volume.vm_seed_iso.pool
            volume = libvirt_volume.vm_seed_iso.name
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
        source = {
          pty = {}
        }
        target = {
          port = 0
          type = "isa-serial"
        }
      }
    ]

    consoles = [
      {
        source = {
          pty = {}
        }
        target = {
          port = 0
          type = "serial"
        }
      }
    ]

    channels = var.install_qemu_guest_agent ? [
      {
        source = {
          pty = {}
        }
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
