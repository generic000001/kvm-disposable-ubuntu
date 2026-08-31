#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-12}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"

discover_from_domifaddr() {
  local vm_name="${1:?vm name required}"
  local uri="${2:?uri required}"
  local line address
  while IFS= read -r line; do
    address="$(awk '/ipv4/ {print $4}' <<<"${line}")"
    if [[ -n "${address}" ]]; then
      printf '%s\n' "${address%%/*}"
      return 0
    fi
  done < <(virsh -c "${uri}" domifaddr "${vm_name}" --source lease 2>/dev/null || true)
  return 1
}

discover_from_dhcp_leases() {
  local vm_name="${1:?vm name required}"
  local network_name="${2:?network name required}"
  local line hostname address
  while IFS= read -r line; do
    hostname="$(awk '{print $6}' <<<"${line}")"
    address="$(awk '{print $5}' <<<"${line}")"
    if [[ "${hostname}" == "${vm_name}" && -n "${address}" ]]; then
      printf '%s\n' "${address%%/*}"
      return 0
    fi
  done < <(virsh -c qemu:///system net-dhcp-leases "${network_name}" 2>/dev/null || true)
  return 1
}

main() {
  ensure_command awk
  ensure_command virsh
  local attempt vm_name uri network_name ip_address

  if terraform_available && terraform_state_present; then
    vm_name="$(terraform_output_raw vm_name 2>/dev/null || true)"
    uri="$(terraform_output_raw libvirt_connection_uri 2>/dev/null || true)"
    network_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw libvirt_network_name 2>/dev/null || true)"
  fi

  vm_name="${vm_name:-$(default_vm_name)}"
  uri="${uri:-qemu:///system}"
  network_name="${network_name:-default}"

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1)); do
    if ip_address="$(discover_from_domifaddr "${vm_name}" "${uri}")"; then
      printf '%s\n' "${ip_address}"
      return 0
    fi
    if ip_address="$(discover_from_dhcp_leases "${vm_name}" "${network_name}")"; then
      printf '%s\n' "${ip_address}"
      return 0
    fi
    if [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; then
      warn "VM IP address not available yet (attempt ${attempt}/${MAX_ATTEMPTS}); retrying in ${SLEEP_SECONDS}s."
      sleep "${SLEEP_SECONDS}"
    fi
  done

  die "Unable to discover a VM IP address after ${MAX_ATTEMPTS} attempts."
}

main "$@"
