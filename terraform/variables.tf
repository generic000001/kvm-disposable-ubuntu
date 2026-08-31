variable "vm_name" {
  description = "Virtual machine name."
  type        = string
  default     = "disposable-ubuntu"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}$", var.vm_name))
    error_message = "vm_name must start with a letter or digit and contain only lowercase letters, digits, and hyphens."
  }
}

variable "vm_vcpus" {
  description = "Number of virtual CPUs assigned to the guest."
  type        = number
  default     = 2

  validation {
    condition     = var.vm_vcpus >= 1 && floor(var.vm_vcpus) == var.vm_vcpus
    error_message = "vm_vcpus must be a whole number greater than or equal to 1."
  }
}

variable "vm_memory_mb" {
  description = "Guest memory in MiB."
  type        = number
  default     = 4096

  validation {
    condition     = var.vm_memory_mb >= 1024 && floor(var.vm_memory_mb) == var.vm_memory_mb
    error_message = "vm_memory_mb must be a whole number greater than or equal to 1024."
  }
}

variable "vm_disk_size_gb" {
  description = "Size of the copy-on-write guest disk in GiB."
  type        = number
  default     = 32

  validation {
    condition     = var.vm_disk_size_gb >= 8 && floor(var.vm_disk_size_gb) == var.vm_disk_size_gb
    error_message = "vm_disk_size_gb must be a whole number greater than or equal to 8."
  }
}

variable "ubuntu_image_path" {
  description = "Path to a local verified Ubuntu source or golden image."
  type        = string
  default     = "../images/ubuntu-26.04-server-cloudimg-amd64.img"

  validation {
    condition     = length(trimspace(var.ubuntu_image_path)) > 0
    error_message = "ubuntu_image_path must not be empty."
  }
}

variable "username" {
  description = "Non-root login account created inside the guest."
  type        = string
  default     = "ubuntu"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,30}$", var.username))
    error_message = "username must be a conventional Linux account name."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key injected into the guest."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"

  validation {
    condition     = length(trimspace(var.ssh_public_key_path)) > 0
    error_message = "ssh_public_key_path must not be empty."
  }
}

variable "timezone" {
  description = "Guest timezone."
  type        = string
  default     = "UTC"

  validation {
    condition     = length(trimspace(var.timezone)) > 0
    error_message = "timezone must not be empty."
  }
}

variable "locale" {
  description = "Guest locale."
  type        = string
  default     = "en_GB.UTF-8"

  validation {
    condition     = can(regex("^[A-Za-z_\\.0-9-]+$", var.locale))
    error_message = "locale must be a plausible locale identifier such as en_GB.UTF-8."
  }
}

variable "install_docker" {
  description = "Install Docker Engine and Docker Compose support from Ubuntu packages during cloud-init."
  type        = bool
  default     = true
}

variable "install_qemu_guest_agent" {
  description = "Install and enable qemu-guest-agent inside the guest."
  type        = bool
  default     = true
}

variable "libvirt_uri" {
  description = "Libvirt connection URI."
  type        = string
  default     = "qemu:///system"

  validation {
    condition     = trimspace(var.libvirt_uri) == "qemu:///system"
    error_message = "This repository is designed for the libvirt system connection qemu:///system."
  }
}

variable "libvirt_network_name" {
  description = "Libvirt network used for the guest interface."
  type        = string
  default     = "default"

  validation {
    condition     = length(trimspace(var.libvirt_network_name)) > 0
    error_message = "libvirt_network_name must not be empty."
  }
}
