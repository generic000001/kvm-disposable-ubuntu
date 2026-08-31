#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/common.sh"

INSTALL_VIRT_MANAGER="${INSTALL_VIRT_MANAGER:-0}"
SUPPORTED_UBUNTU_MAJOR_MIN=24

SUDO_READY=0
GROUP_REFRESH_REQUIRED=0

cleanup() {
  local exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    warn "bootstrap.sh failed with exit code ${exit_code}"
  fi
}
trap cleanup EXIT

require_sudo_once() {
  if [[ "${SUDO_READY}" -eq 0 ]]; then
    sudo -v
    SUDO_READY=1
  fi
}

apt_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fq 'install ok installed'
}

record_package_state() {
  local package_name="${1:?package required}"
  if apt_package_installed "${package_name}"; then
    manifest_add_unique_string "packages_preexisting" "${package_name}"
  fi
}

ensure_packages() {
  local package_name missing_packages=()
  for package_name in "$@"; do
    record_package_state "${package_name}"
    if ! apt_package_installed "${package_name}"; then
      missing_packages+=("${package_name}")
    fi
  done

  if [[ ${#missing_packages[@]} -eq 0 ]]; then
    log "All required APT packages are already installed."
    return 0
  fi

  log "Installing missing APT packages: ${missing_packages[*]}"
  require_sudo_once
  sudo apt-get update
  sudo apt-get install -y "${missing_packages[@]}"

  for package_name in "${missing_packages[@]}"; do
    manifest_add_unique_string "packages_installed" "${package_name}"
  done
}

ensure_hashicorp_repo() {
  local keyring_path source_path distro_arch repo_entry tmp_keyring
  distro_arch="$(dpkg --print-architecture)"
  keyring_path="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
  source_path="/etc/apt/sources.list.d/hashicorp.list"
  repo_entry="deb [arch=${distro_arch} signed-by=${keyring_path}] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main"

  require_sudo_once

  if [[ ! -f "${keyring_path}" ]]; then
    tmp_keyring="$(mktemp)"
    trap 'cleanup_temp_file "${tmp_keyring}"' RETURN
    curl --fail --silent --show-error https://apt.releases.hashicorp.com/gpg | gpg --dearmor >"${tmp_keyring}"
    sudo install -o root -g root -m 0644 "${tmp_keyring}" "${keyring_path}"
    manifest_add_unique_string "keyring_files_created" "${keyring_path}"
    trap - RETURN
  fi

  if [[ -f "${source_path}" ]]; then
    if grep -Fqx "${repo_entry}" "${source_path}"; then
      log "HashiCorp APT source already configured."
    else
      die "Existing ${source_path} does not match the expected signed-by configuration."
    fi
  else
    printf '%s\n' "${repo_entry}" | sudo tee "${source_path}" >/dev/null
    manifest_add_unique_string "apt_sources_created" "${source_path}"
  fi

  sudo apt-get update
}

ensure_user_groups() {
  local invoking_user changed=0
  invoking_user="$(current_user_name)"

  if ! current_user_in_group "${invoking_user}" kvm; then
    require_sudo_once
    sudo usermod -aG kvm "${invoking_user}"
    manifest_add_unique_string "group_membership_changes" "${invoking_user}:kvm"
    changed=1
  fi

  if ! current_user_in_group "${invoking_user}" libvirt; then
    require_sudo_once
    sudo usermod -aG libvirt "${invoking_user}"
    manifest_add_unique_string "group_membership_changes" "${invoking_user}:libvirt"
    changed=1
  fi

  if [[ "${changed}" -eq 1 ]]; then
    GROUP_REFRESH_REQUIRED=1
    mark_group_refresh_required
    warn "Group membership changed for ${invoking_user}; sign out and back in before using libvirt without sudo."
  elif current_session_in_group kvm && current_session_in_group libvirt; then
    clear_group_refresh_marker
  fi
}

enable_libvirt_services() {
  local service_name enabled_any=0
  require_sudo_once
  for service_name in virtqemud.socket virtnetworkd.socket virtlogd.socket libvirtd.socket libvirtd.service; do
    if systemctl list-unit-files "${service_name}" >/dev/null 2>&1; then
      sudo systemctl enable --now "${service_name}"
      manifest_add_unique_string "services_enabled" "${service_name}"
      enabled_any=1
    fi
  done
  [[ "${enabled_any}" -eq 1 ]] || die "No supported libvirt service or socket units were found."
}

ensure_default_network() {
  require_sudo_once
  if virsh -c qemu:///system net-info default >/dev/null 2>&1; then
    if ! virsh -c qemu:///system net-info default | grep -Fq 'Active:         yes'; then
      sudo virsh -c qemu:///system net-start default
    fi
    sudo virsh -c qemu:///system net-autostart default
    return 0
  fi

  [[ -f /usr/share/libvirt/networks/default.xml ]] || die "The default libvirt network definition is unavailable."
  sudo virsh -c qemu:///system net-define /usr/share/libvirt/networks/default.xml
  sudo virsh -c qemu:///system net-start default
  sudo virsh -c qemu:///system net-autostart default
}

validate_host() {
  local arch major_version
  load_os_release
  [[ "${ID}" == "ubuntu" ]] || die "Unsupported host distribution: ${ID}"
  major_version="${VERSION_ID%%.*}"
  [[ "${major_version}" -ge "${SUPPORTED_UBUNTU_MAJOR_MIN}" ]] || die "Unsupported Ubuntu release: ${VERSION_ID}"

  arch="$(host_architecture)"
  [[ "${arch}" == "x86_64" || "${arch}" == "amd64" ]] || die "Unsupported architecture: ${arch}"

  if [[ ! -e /dev/kvm ]]; then
    if grep -qm1 -F 'GenuineIntel' /proc/cpuinfo && ! grep -qm1 -w vmx /proc/cpuinfo; then
      die "/dev/kvm is missing and Intel VT-x does not appear enabled in firmware."
    fi
    if ! grep -qm1 -E '(^|\s)(vmx|svm)(\s|$)' /proc/cpuinfo; then
      die "Hardware virtualisation flags are missing; the CPU or firmware does not expose VT-x/SVM."
    fi
    die "/dev/kvm is missing even though CPU virtualisation flags exist; check firmware and host KVM modules."
  fi
}

main() {
  ensure_repo_layout
  create_local_dirs
  manifest_init
  manifest_add_unique_string "directories_created" "${STATE_DIR}"
  validate_host

  local required_packages optional_packages summary_provider_version
  required_packages=(
    ca-certificates
    curl
    gpg
    jq
    qemu-system-x86
    qemu-utils
    libvirt-daemon-system
    libvirt-clients
    virtinst
    cloud-image-utils
    genisoimage
    dnsmasq-base
    bridge-utils
    cpu-checker
  )
  optional_packages=(virt-manager)

  ensure_packages "${required_packages[@]}"
  ensure_hashicorp_repo
  if ! apt_package_installed terraform; then
    ensure_packages terraform
  fi
  if [[ "${INSTALL_VIRT_MANAGER}" == "1" ]]; then
    ensure_packages "${optional_packages[@]}"
  fi

  ensure_user_groups
  enable_libvirt_services
  ensure_default_network

  if [[ "${GROUP_REFRESH_REQUIRED}" -eq 1 ]] || group_refresh_required || ! current_session_in_group libvirt; then
    sudo virsh -c qemu:///system uri >/dev/null
    sudo virsh -c qemu:///system net-info default >/dev/null
  else
    virsh -c qemu:///system uri >/dev/null
    virsh -c qemu:///system net-info default >/dev/null
  fi
  terraform version >/dev/null

  summary_provider_version="${DEFAULT_PROVIDER_VERSION}"
  manifest_set_value "selected_provider_version" "${summary_provider_version}"
  manifest_set_value "selected_image_version" "${DEFAULT_IMAGE_RELEASE}"

  log "Bootstrap completed successfully."
  printf '\nSummary\n'
  printf '  Ubuntu host:             %s\n' "${PRETTY_NAME}"
  printf '  Architecture:            %s\n' "$(host_architecture)"
  printf '  Terraform provider pin:  %s\n' "${summary_provider_version}"
  printf '  Ubuntu image release:    %s (%s)\n' "${DEFAULT_IMAGE_RELEASE}" "${DEFAULT_IMAGE_CODENAME}"
  printf '  Manifest path:           %s\n' "${MANIFEST_PATH}"
  printf '  Sign-out required:       %s\n' "$(group_refresh_required && printf yes || printf no)"
}

main "$@"
