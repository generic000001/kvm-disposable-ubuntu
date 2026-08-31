locals {
  image_path        = abspath(pathexpand(var.ubuntu_image_path))
  ssh_public_key    = trimspace(file(pathexpand(var.ssh_public_key_path)))
  vm_disk_bytes     = var.vm_disk_size_gb * 1024 * 1024 * 1024
  resource_prefix   = "kvm-disposable-ubuntu"
  pool_name         = "${local.resource_prefix}-pool"
  pool_path         = "${path.root}/.generated/pool"
  description       = "Disposable Ubuntu VM managed by Terraform, libvirt, and cloud-init."
  cloudinit_name    = "${var.vm_name}-cloudinit"
  base_volume_name  = "${var.vm_name}-base.qcow2"
  guest_volume_name = "${var.vm_name}-overlay.qcow2"
  seed_volume_name  = "${var.vm_name}-cloudinit.iso"
  domain_addresses  = try(flatten([
    for iface in data.libvirt_domain_interface_addresses.vm.interfaces : [
      for addr in iface.addrs : addr
      if addr.type == "ipv4"
    ]
  ]), [])
  primary_ipv4 = try(local.domain_addresses[0].addr, null)
}
