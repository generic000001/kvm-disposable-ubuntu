#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MODE="${1:-strict}"

report_line() {
  printf '%-32s %s\n' "$1" "$2"
}

main() {
  load_os_release
  local arch user_name kvm_device vmx_present ssh_key state_text
  arch="$(host_architecture)"
  user_name="$(current_user_name)"

  if [[ -e /dev/kvm ]]; then
    kvm_device="present"
  else
    kvm_device="missing"
  fi

  if grep -qm1 -E '(^|\s)(vmx|svm)(\s|$)' /proc/cpuinfo; then
    vmx_present="yes"
  else
    vmx_present="no"
  fi

  if compgen -G "${HOME}/.ssh/*.pub" >/dev/null 2>&1; then
    ssh_key="present"
  else
    ssh_key="missing"
  fi

  report_line "Ubuntu release" "${PRETTY_NAME}"
  report_line "Ubuntu codename" "${VERSION_CODENAME:-unknown}"
  report_line "Architecture" "${arch}"
  report_line "/dev/kvm" "${kvm_device}"
  report_line "CPU virtualisation flag" "${vmx_present}"
  report_line "Git" "$(command -v git >/dev/null 2>&1 && printf present || printf missing)"
  report_line "Terraform" "$(terraform_available && printf present || printf missing)"
  report_line "virsh" "$(virsh_available && printf present || printf missing)"
  report_line "qemu-system-x86_64" "$(command -v qemu-system-x86_64 >/dev/null 2>&1 && printf present || printf missing)"
  report_line "Account in libvirt group" "$(current_user_in_group "${user_name}" libvirt && printf yes || printf no)"
  report_line "Account in kvm group" "$(current_user_in_group "${user_name}" kvm && printf yes || printf no)"
  report_line "Current session libvirt" "$(current_session_in_group libvirt && printf yes || printf no)"
  report_line "Current session kvm" "$(current_session_in_group kvm && printf yes || printf no)"
  report_line "SSH public key" "${ssh_key}"
  report_line "Session refresh required" "$(group_refresh_required && printf yes || printf no)"

  if virsh_available; then
    if state_text="$(virsh -c qemu:///system uri 2>/dev/null)"; then
      report_line "libvirt system URI" "${state_text}"
      report_line "default network" "$(virsh -c qemu:///system net-info default >/dev/null 2>&1 && printf present || printf missing)"
    else
      report_line "libvirt system URI" "unavailable"
      report_line "default network" "unknown"
    fi
  else
    report_line "libvirt system URI" "virsh not installed"
    report_line "default network" "virsh not installed"
  fi

  if [[ "${MODE}" == "--advisory" ]]; then
    exit 0
  fi

  [[ "${ID}" == "ubuntu" ]] || die "This repository supports Ubuntu hosts only."
  [[ "${arch}" == "x86_64" || "${arch}" == "amd64" ]] || die "This repository currently supports amd64/x86_64 hosts only."
}

main "$@"
