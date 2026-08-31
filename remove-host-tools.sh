#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/common.sh"

removed_items=()
retained_items=()
manual_attention=()

require_manifest_or_warn() {
  if [[ ! -f "${MANIFEST_PATH}" ]]; then
    warn "Installation manifest not found; removal will be conservative."
    manual_attention+=("Install manifest missing: ${MANIFEST_PATH}")
  fi
}

append_removed() {
  removed_items+=("$1")
}

append_retained() {
  retained_items+=("$1")
}

maybe_destroy_terraform_resources() {
  local state_listing

  if ! terraform_state_present; then
    append_retained "Terraform-managed resources (no local Terraform state file found)"
    return 0
  fi

  if ! terraform_available; then
    append_retained "Terraform-managed resources (Terraform state exists but terraform is unavailable)"
    die "Terraform state exists but terraform is not available to inspect or destroy resources safely."
  fi

  if ! state_listing="$(terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null)"; then
    append_retained "Terraform-managed resources (state exists but could not be inspected safely)"
    warn "Terraform state exists but could not be inspected safely."
    if confirm "Run terraform destroy now"; then
      terraform -chdir="${TERRAFORM_DIR}" destroy
      append_removed "Terraform-managed infrastructure"
      return 0
    fi
    die "Refusing to continue while Terraform-managed resources may still exist."
  fi

  if [[ -n "${state_listing}" ]]; then
    warn "Terraform-managed resources may still exist."
    if confirm "Run terraform destroy now"; then
      terraform -chdir="${TERRAFORM_DIR}" destroy
      append_removed "Terraform-managed infrastructure"
    else
      append_retained "Terraform-managed infrastructure"
      die "Refusing to continue while Terraform-managed resources may still exist."
    fi
  else
    append_retained "Terraform state file present but no resources listed"
  fi
}

remove_path_if_confirmed() {
  local label="${1:?label required}"
  local target="${2:?path required}"
  if [[ -e "${target}" ]]; then
    if confirm "Remove ${label}: ${target}"; then
      safe_rm_path "${target}"
      append_removed "${label}"
    else
      append_retained "${label}"
    fi
  fi
}

remove_manifest_packages() {
  local package_names=()
  while IFS= read -r package_name; do
    [[ -n "${package_name}" ]] && package_names+=("${package_name}")
  done < <(jq_get_manifest_array packages_installed)

  if [[ ${#package_names[@]} -eq 0 ]]; then
    append_retained "APT packages (manifest did not record project-installed packages)"
    return 0
  fi

  if confirm "Purge project-installed APT packages: ${package_names[*]}"; then
    sudo apt-get purge -y "${package_names[@]}"
    append_removed "Project-installed APT packages"
  else
    append_retained "Project-installed APT packages"
  fi
}

remove_recorded_sources_and_keyrings() {
  local path_value
  while IFS= read -r path_value; do
    [[ -n "${path_value}" ]] || continue
    if [[ -f "${path_value}" ]] && confirm "Remove recorded APT source file ${path_value}"; then
      sudo rm -f -- "${path_value}"
      append_removed "APT source ${path_value}"
    else
      append_retained "APT source ${path_value}"
    fi
  done < <(jq_get_manifest_array apt_sources_created)

  while IFS= read -r path_value; do
    [[ -n "${path_value}" ]] || continue
    if [[ -f "${path_value}" ]] && confirm "Remove recorded keyring file ${path_value}"; then
      sudo rm -f -- "${path_value}"
      append_removed "Keyring ${path_value}"
    else
      append_retained "Keyring ${path_value}"
    fi
  done < <(jq_get_manifest_array keyring_files_created)
}

remove_group_memberships() {
  local invoking_user group_name
  invoking_user="$(current_user_name)"
  for group_name in kvm libvirt; do
    if current_user_in_group "${invoking_user}" "${group_name}"; then
      if confirm "Remove ${invoking_user} from the ${group_name} group"; then
        sudo gpasswd -d "${invoking_user}" "${group_name}"
        append_removed "Group ${group_name} for ${invoking_user}"
      else
        append_retained "Group ${group_name} for ${invoking_user}"
      fi
    fi
  done
}

main() {
  create_local_dirs
  require_manifest_or_warn
  sudo -v

  maybe_destroy_terraform_resources

  if virsh_available; then
    warn "Review unrelated libvirt resources before removing host tooling:"
    virsh -c qemu:///system list --all || true
    virsh -c qemu:///system pool-list --all || true
    virsh -c qemu:///system net-list --all || true
  fi

  remove_path_if_confirmed "Terraform working directory cache" "${TERRAFORM_DIR}/.terraform"
  remove_path_if_confirmed "Project local cache" "${CACHE_DIR}"
  remove_path_if_confirmed "Temporary files" "${TMP_DIR}"
  remove_path_if_confirmed "Offline bundles" "${DIST_DIR}"
  remove_path_if_confirmed "Cached Ubuntu images" "${IMAGES_DIR}/${DEFAULT_IMAGE_FILENAME}"
  remove_path_if_confirmed "Cached checksum manifest" "${IMAGES_DIR}/${DEFAULT_IMAGE_FILENAME}.SHA256SUMS"
  remove_path_if_confirmed "Cached checksum signature" "${IMAGES_DIR}/${DEFAULT_IMAGE_FILENAME}.SHA256SUMS.gpg"
  remove_path_if_confirmed "Cached image metadata" "${IMAGES_DIR}/${DEFAULT_IMAGE_FILENAME}.metadata.json"

  remove_recorded_sources_and_keyrings
  remove_manifest_packages
  remove_group_memberships

  printf '\nFinal report\n'
  printf '  Removed:\n'
  if [[ ${#removed_items[@]} -eq 0 ]]; then
    printf '    - nothing\n'
  else
    printf '    - %s\n' "${removed_items[@]}"
  fi
  printf '  Retained:\n'
  if [[ ${#retained_items[@]} -eq 0 ]]; then
    printf '    - nothing\n'
  else
    printf '    - %s\n' "${retained_items[@]}"
  fi
  printf '  Manual attention:\n'
  if [[ ${#manual_attention[@]} -eq 0 ]]; then
    printf '    - none\n'
  else
    printf '    - %s\n' "${manual_attention[@]}"
  fi

  warn "If group membership was changed, sign out and back in before relying on the new access model."
}

main "$@"
