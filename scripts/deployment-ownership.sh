#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

usage() {
  printf 'Usage: %s check|status|adopt|destroy-existing\n' "${0##*/}" >&2
}

terraform_value() {
  local expression="${1:?Terraform expression required}"
  local value
  if ! value="$(printf '%s\n' "${expression}" | terraform -chdir="${TERRAFORM_DIR}" console -no-color 2>/dev/null)"; then
    terraform -chdir="${TERRAFORM_DIR}" init -backend=false >/dev/null \
      || die "Could not initialise Terraform while resolving ${expression}."
    value="$(printf '%s\n' "${expression}" | terraform -chdir="${TERRAFORM_DIR}" console -no-color 2>/dev/null)" \
      || die "Could not resolve ${expression} from the Terraform configuration."
  fi
  value="${value#\"}"
  value="${value%\"}"
  [[ -n "${value}" ]] || die "Terraform expression ${expression} resolved to an empty value."
  printf '%s\n' "${value}"
}

load_resources() {
  ensure_command terraform
  ensure_command virsh

  POOL_NAME="$(terraform_value local.pool_name)"
  POOL_PATH="$(terraform_value local.pool_path)"
  VM_NAME="$(terraform_value var.vm_name)"
  VOLUME_KEY="$(terraform_value local.managed_volume_permissions_revision)"
  BASE_VOLUME_NAME="$(terraform_value local.base_volume_name)"
  GUEST_VOLUME_NAME="$(terraform_value local.guest_volume_name)"
  SEED_VOLUME_NAME="$(terraform_value local.seed_volume_name)"
  POOL_UUID="$(virsh -c qemu:///system pool-uuid "${POOL_NAME}" 2>/dev/null || true)"
  DOMAIN_UUID="$(virsh -c qemu:///system domuuid "${VM_NAME}" 2>/dev/null || true)"
  STATE_LIST="$(terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null || true)"
}

state_owns() {
  grep -Fxq -- "$1" <<<"${STATE_LIST}"
}

volume_exists() {
  virsh -c qemu:///system vol-info --pool="${POOL_NAME}" "$1" >/dev/null 2>&1
}

pool_exists() {
  virsh -c qemu:///system pool-info "${POOL_NAME}" >/dev/null 2>&1
}

pool_path_matches() {
  pool_exists || return 1
  virsh -c qemu:///system pool-dumpxml "${POOL_NAME}" 2>/dev/null |
    grep -Fq "<path>${POOL_PATH}</path>"
}

domain_exists() {
  virsh -c qemu:///system dominfo "${VM_NAME}" >/dev/null 2>&1
}

physical_count() {
  local count=0
  pool_exists && ((count += 1))
  domain_exists && ((count += 1))
  volume_exists "${BASE_VOLUME_NAME}" && ((count += 1))
  volume_exists "${GUEST_VOLUME_NAME}" && ((count += 1))
  volume_exists "${SEED_VOLUME_NAME}" && ((count += 1))
  printf '%s\n' "${count}"
}

expected_addresses() {
  printf '%s\n' \
    'libvirt_pool.vm_pool' \
    "libvirt_volume.base_image[\"${VOLUME_KEY}\"]" \
    "libvirt_volume.vm_disk[\"${VOLUME_KEY}\"]" \
    "libvirt_volume.vm_seed_iso[\"${VOLUME_KEY}\"]" \
    'libvirt_domain.vm'
}

ownership_gaps() {
  local address
  while IFS= read -r address; do
    state_owns "${address}" || printf '%s\n' "${address}"
  done < <(expected_addresses)
}

check_ownership() {
  load_resources
  if [[ "$(physical_count)" -eq 0 ]]; then
    return 0
  fi

  local gaps
  gaps="$(ownership_gaps)"
  if [[ -n "${gaps}" ]]; then
    printf '[ERROR] Existing libvirt deployment resources are not fully owned by this Terraform state.\n' >&2
    printf '[ERROR] Pool: %s (%s)\n' "${POOL_NAME}" "${POOL_PATH}" >&2
    printf '[ERROR] Missing ownership for:\n%s\n' "${gaps}" >&2
    printf '[ERROR] Refusing to create because Terraform could replace or destroy resources it does not own.\n' >&2
    printf '[ERROR] Choose explicitly: make adopt or make destroy-existing.\n' >&2
    return 1
  fi
}

print_status() {
  load_resources
  local address state_text gaps
  printf '%-28s %s\n' "Deployment pool" "${POOL_NAME}"
  printf '%-28s %s\n' "Deployment pool path" "${POOL_PATH}"
  printf '%-28s %s\n' "Fixed resources present" "$(physical_count)"
  if [[ "$(physical_count)" -eq 0 ]]; then
    printf '%-28s %s\n' "Ownership" "no existing resources"
    return 0
  fi
  gaps="$(ownership_gaps)"
  if [[ -n "${gaps}" ]]; then
    printf '%-28s %s\n' "Ownership" "INCOMPLETE (create blocked)"
    printf '%-28s %s\n' "Suggested action" "make adopt or make destroy-existing"
  else
    printf '%-28s %s\n' "Ownership" "complete"
  fi
  while IFS= read -r address; do
    if state_owns "${address}"; then state_text="owned"; else state_text="NOT OWNED"; fi
    printf '%-28s %s\n' "${address}" "${state_text}"
  done < <(expected_addresses)
  if [[ -n "${gaps}" ]]; then
    printf '%s\n' "The deployment exists but is not fully managed by this Terraform state."
    printf '%s\n' "Review the resources, then run make adopt or make destroy-existing."
  fi
}

import_if_missing() {
  local address="$1" import_id="$2"
  if state_owns "${address}"; then
    printf '[INFO] Already owned: %s\n' "${address}"
  else
    printf '[INFO] Importing %s\n' "${address}"
    terraform -chdir="${TERRAFORM_DIR}" import "${address}" "${import_id}"
  fi
}

adopt() {
  load_resources
  [[ "$(physical_count)" -gt 0 ]] || die "No existing fixed libvirt deployment resources were found to adopt."
  local gaps
  gaps="$(ownership_gaps)"
  [[ -n "${gaps}" ]] || die "Terraform already fully owns the fixed deployment resources; use make create or make destroy."
  pool_exists || die "Cannot adopt partially existing resources: libvirt pool ${POOL_NAME} is missing."
  pool_path_matches || die "Cannot adopt: pool ${POOL_NAME} does not use configured path ${POOL_PATH}."
  domain_exists || die "Cannot adopt partially existing resources: libvirt domain ${VM_NAME} is missing."
  volume_exists "${BASE_VOLUME_NAME}" || die "Cannot adopt: volume ${BASE_VOLUME_NAME} is missing."
  volume_exists "${GUEST_VOLUME_NAME}" || die "Cannot adopt: volume ${GUEST_VOLUME_NAME} is missing."
  volume_exists "${SEED_VOLUME_NAME}" || die "Cannot adopt: volume ${SEED_VOLUME_NAME} is missing."
  printf '[INFO] Adopting existing resources into the current Terraform state.\n'
  [[ -n "${POOL_UUID}" ]] || die "Cannot adopt: could not resolve UUID for pool ${POOL_NAME}."
  [[ -n "${DOMAIN_UUID}" ]] || die "Cannot adopt: could not resolve UUID for domain ${VM_NAME}."
  import_if_missing 'libvirt_pool.vm_pool' "${POOL_UUID}"
  import_if_missing "libvirt_volume.base_image[\"${VOLUME_KEY}\"]" "${POOL_PATH}/${BASE_VOLUME_NAME}"
  import_if_missing "libvirt_volume.vm_disk[\"${VOLUME_KEY}\"]" "${POOL_PATH}/${GUEST_VOLUME_NAME}"
  import_if_missing "libvirt_volume.vm_seed_iso[\"${VOLUME_KEY}\"]" "${POOL_PATH}/${SEED_VOLUME_NAME}"
  import_if_missing 'libvirt_domain.vm' "${DOMAIN_UUID}"
  printf '[INFO] Adoption complete. Run make plan before make create.\n'
}

destroy_existing() {
  load_resources
  [[ "$(physical_count)" -gt 0 ]] || die "No existing fixed libvirt deployment resources were found."
  local gaps volume extra
  gaps="$(ownership_gaps)"
  [[ -n "${gaps}" ]] || die "Terraform fully owns this deployment; use make destroy instead."
  if pool_exists; then
    pool_path_matches || die "Refusing to destroy pool ${POOL_NAME}; it does not use configured path ${POOL_PATH}."
    while IFS= read -r volume; do
      case "${volume}" in
        "${BASE_VOLUME_NAME}"|"${GUEST_VOLUME_NAME}"|"${SEED_VOLUME_NAME}"|"") ;;
        *) extra="${extra:-}${volume}\n" ;;
      esac
    done < <(virsh -c qemu:///system vol-list --name "${POOL_NAME}" 2>/dev/null || true)
    [[ -z "${extra:-}" ]] || die "Refusing to destroy pool ${POOL_NAME}; it contains non-deployment volumes: ${extra//$'\n'/ }"
  fi
  printf 'This will permanently remove the existing deployment resources in pool %s and domain %s.\n' "${POOL_NAME}" "${VM_NAME}"
  confirm "Destroy existing libvirt deployment resources" || die "Destruction cancelled."
  if domain_exists; then
    virsh -c qemu:///system destroy "${VM_NAME}" >/dev/null 2>&1 || true
    virsh -c qemu:///system undefine "${VM_NAME}" --nvram >/dev/null 2>&1 || virsh -c qemu:///system undefine "${VM_NAME}"
  fi
  for volume in "${SEED_VOLUME_NAME}" "${GUEST_VOLUME_NAME}" "${BASE_VOLUME_NAME}"; do
    volume_exists "${volume}" && virsh -c qemu:///system vol-delete --pool="${POOL_NAME}" "${volume}"
  done
  if pool_exists; then
    virsh -c qemu:///system pool-destroy "${POOL_NAME}" >/dev/null 2>&1 || true
    virsh -c qemu:///system pool-undefine "${POOL_NAME}"
  fi
  printf '[INFO] Existing deployment resources destroyed. Terraform state was not modified.\n'
}

main() {
  case "${1:-}" in
    check) check_ownership ;;
    status) print_status ;;
    adopt) adopt ;;
    destroy-existing) destroy_existing ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
