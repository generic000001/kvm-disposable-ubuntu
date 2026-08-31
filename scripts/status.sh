#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

report_line() {
  printf '%-28s %s\n' "$1" "$2"
}

main() {
  local vm_name uri domain_state ip_address
  vm_name="$(terraform_output_raw vm_name 2>/dev/null || printf '%s\n' "$(default_vm_name)")"
  uri="$(terraform_output_raw libvirt_connection_uri 2>/dev/null || printf '%s\n' qemu:///system)"

  report_line "Repository" "${REPO_ROOT}"
  report_line "Terraform state" "$(terraform_state_present && printf present || printf missing)"
  report_line "VM name" "${vm_name}"
  report_line "libvirt URI" "${uri}"

  if virsh_available && virsh -c "${uri}" dominfo "${vm_name}" >/dev/null 2>&1; then
    domain_state="$(virsh -c "${uri}" domstate "${vm_name}" | tr -d '\r')"
    report_line "VM exists" "yes"
    report_line "VM state" "${domain_state}"
  else
    report_line "VM exists" "no"
    exit 0
  fi

  if ip_address="$("${SCRIPT_DIR}/discover-vm-ip.sh" 2>/dev/null)"; then
    report_line "VM IPv4" "${ip_address}"
  else
    report_line "VM IPv4" "pending DHCP/guest agent"
  fi

  if command -v terraform >/dev/null 2>&1; then
    report_line "Terraform output" "terraform -chdir=${TERRAFORM_DIR} output"
  fi

  report_line "libvirt diagnostics" "virsh -c ${uri} dominfo ${vm_name}"
}

main "$@"
