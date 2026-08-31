#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

main() {
  ensure_command tar
  ensure_command sha256sum
  create_local_dirs

  local timestamp bundle_name bundle_path hash_path
  timestamp="$(date +%Y%m%dT%H%M%S)"
  bundle_name="${PROJECT_SLUG}-${timestamp}.tar.gz"
  bundle_path="${DIST_DIR}/${bundle_name}"
  hash_path="${bundle_path}.sha256"

  [[ -f "${IMAGES_DIR}/${DEFAULT_IMAGE_FILENAME}" ]] || die "Image cache missing; run make prepare-offline first."
  [[ -d "${CACHE_DIR}/terraform/provider-mirror" ]] || die "Provider mirror missing; run make prepare-offline first."

  tar -C "${REPO_ROOT}" -czf "${bundle_path}" \
    --exclude='.git' \
    --exclude='.terraform' \
    --exclude='terraform/.terraform' \
    --exclude='dist' \
    --exclude='*.tfstate*' \
    --exclude='*.tfplan' \
    README.md LICENSE Makefile .editorconfig .gitignore bootstrap.sh remove-host-tools.sh scripts terraform images examples packer .cache/terraform/provider-mirror

  sha256sum "${bundle_path}" >"${hash_path}"
  log "Offline bundle written to ${bundle_path}"
  log "Bundle checksum written to ${hash_path}"
}

main "$@"
