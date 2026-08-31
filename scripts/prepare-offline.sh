#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

generate_offline_cli_config() {
  local mirror_dir="${1:?mirror dir required}"
  local config_path="${2:?config path required}"
  cat >"${config_path}" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "${mirror_dir}"
    include = ["registry.terraform.io/dmacvicar/libvirt"]
  }
  direct {
    exclude = ["registry.terraform.io/dmacvicar/libvirt"]
  }
}
EOF
}

main() {
  ensure_repo_layout
  create_local_dirs
  ensure_command terraform

  local mirror_dir plugin_cache_dir offline_cli_config golden_image_path offline_mode
  mirror_dir="${CACHE_DIR}/terraform/provider-mirror"
  plugin_cache_dir="${CACHE_DIR}/terraform/plugin-cache"
  offline_cli_config="${CACHE_DIR}/terraform/terraformrc.offline.tfrc"
  golden_image_path="${IMAGES_DIR}/ubuntu-${DEFAULT_IMAGE_RELEASE}-docker-golden-${DEFAULT_IMAGE_ARCH}.qcow2"

  mkdir -p -- "${mirror_dir}" "${plugin_cache_dir}" "$(dirname -- "${offline_cli_config}")"
  record_cache_dir "${mirror_dir}"
  record_cache_dir "${plugin_cache_dir}"

  "${SCRIPT_DIR}/download-image.sh"
  "${SCRIPT_DIR}/verify-image.sh" >/dev/null

  log "Initialising Terraform to generate an authoritative lock file"
  terraform -chdir="${TERRAFORM_DIR}" init -backend=false

  log "Mirroring Terraform providers for offline use"
  terraform -chdir="${TERRAFORM_DIR}" providers mirror "${mirror_dir}"

  generate_offline_cli_config "${mirror_dir}" "${offline_cli_config}"

  if [[ -f "${golden_image_path}" ]]; then
    offline_mode="fully-prepared"
  else
    offline_mode="image-cached"
  fi

  log "Selected offline mode: ${offline_mode}"
  log "Offline Terraform CLI configuration written to ${offline_cli_config}"
}

main "$@"
