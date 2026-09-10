#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

main() {
  ensure_repo_layout
  create_local_dirs
  ensure_command gpg
  ensure_command sha256sum
  ensure_command awk

  local image_path sums_path signature_path expected_sum actual_sum gnupg_home key_fingerprint actual_fingerprint
  local -a manifest_entry=()
  image_path="${IMAGES_DIR}/${DEFAULT_IMAGE_FILENAME}"
  sums_path="${image_path}.SHA256SUMS"
  signature_path="${image_path}.SHA256SUMS.gpg"
  gnupg_home="$(ubuntu_cloud_image_gnupg_home)"
  key_fingerprint="${UBUNTU_CLOUD_IMAGE_SIGNING_KEY_FINGERPRINT}"

  [[ -f "${image_path}" ]] || die "Cached image missing: ${image_path}"
  [[ -f "${sums_path}" ]] || die "Checksum manifest missing: ${sums_path}"
  [[ -f "${signature_path}" ]] || die "Checksum signature missing: ${signature_path}"

  ensure_private_dir "${STATE_DIR}/gnupg"
  ensure_private_dir "${gnupg_home}"
  manifest_add_unique_string "directories_created" "${STATE_DIR}/gnupg"
  manifest_add_unique_string "directories_created" "${gnupg_home}"

  if ! gpg --homedir "${gnupg_home}" --list-keys "${key_fingerprint}" >/dev/null 2>&1; then
    log "Importing Ubuntu cloud image signing key ${key_fingerprint}"
    gpg --homedir "${gnupg_home}" --keyserver hkps://keyserver.ubuntu.com --recv-keys "${key_fingerprint}" \
      || gpg --homedir "${gnupg_home}" --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "${key_fingerprint}"
  fi

  actual_fingerprint="$(gpg --homedir "${gnupg_home}" --with-colons --fingerprint "${key_fingerprint}" | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ "${actual_fingerprint}" == "${key_fingerprint}" ]] || die "Unexpected GPG fingerprint for the Ubuntu image signing key."

  gpg --homedir "${gnupg_home}" --batch --verify "${signature_path}" "${sums_path}" >/dev/null 2>&1 \
    || die "SHA256SUMS signature verification failed."

  mapfile -t manifest_entry < <(find_sha256_manifest_entry "${sums_path}" "${DEFAULT_IMAGE_FILENAME}") \
    || die "Checksum manifest does not contain a valid entry for ${DEFAULT_IMAGE_FILENAME}"
  [[ ${#manifest_entry[@]} -eq 2 ]] || die "Invalid checksum parser result for ${DEFAULT_IMAGE_FILENAME}"
  log "Matched checksum manifest entry: ${manifest_entry[0]}"
  expected_sum="${manifest_entry[1]}"
  log "Extracted checksum: ${expected_sum}"

  actual_sum="$(sha256sum "${image_path}" | awk '{print $1}')"
  [[ "${expected_sum}" == "${actual_sum}" ]] || die "Cached image checksum verification failed."

  log "Image verification succeeded for ${image_path}"
  printf '%s\n' "${actual_sum}"
}

main "$@"
