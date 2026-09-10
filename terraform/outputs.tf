output "vm_name" {
  description = "Virtual machine name."
  value       = libvirt_domain.vm.name
}

output "vm_identifier" {
  description = "Libvirt domain identifier."
  value       = libvirt_domain.vm.id
}

output "vm_ip_address" {
  description = "First discovered IPv4 address, if one is available yet."
  value       = local.primary_ipv4
}

output "ssh_username" {
  description = "Guest SSH username."
  value       = var.username
}

output "ssh_command" {
  description = "Suggested SSH command once the VM has an IP address."
  value       = local.primary_ipv4 == null ? "VM IP pending; run make ip or make status first." : "ssh ${var.username}@${local.primary_ipv4}"
}

output "libvirt_connection_uri" {
  description = "Libvirt connection URI."
  value       = var.libvirt_uri
}

output "libvirt_network_name" {
  description = "Libvirt network name."
  value       = var.libvirt_network_name
}

output "libvirt_pool_path" {
  description = "Resolved absolute path of the Terraform-managed libvirt storage pool."
  value       = libvirt_pool.vm_pool.target.path
}

output "disk_volume_information" {
  description = "Relevant disk and pool metadata."
  value = {
    pool_name        = libvirt_pool.vm_pool.name
    pool_path        = libvirt_pool.vm_pool.target.path
    base_volume_name = libvirt_volume.base_image[local.managed_volume_permissions_revision].name
    base_volume_path = libvirt_volume.base_image[local.managed_volume_permissions_revision].path
    vm_volume_name   = libvirt_volume.vm_disk[local.managed_volume_permissions_revision].name
    vm_volume_path   = libvirt_volume.vm_disk[local.managed_volume_permissions_revision].path
    seed_volume_name = libvirt_volume.vm_seed_iso[local.managed_volume_permissions_revision].name
    seed_volume_path = libvirt_volume.vm_seed_iso[local.managed_volume_permissions_revision].path
  }
}

output "cloud_init_completion_guidance" {
  description = "How to wait for cloud-init completion."
  value       = "Run make cloud-init-status after creation. If the VM is up but not ready, run make status and then make ssh."
}
