#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

FORCE_REFRESH=0
for arg in "$@"; do
  case "${arg}" in
    --force|--refresh)
      FORCE_REFRESH=1
      ;;
    *)
      die "Unsupported argument: ${arg}"
      ;;
  esac
done

cleanup_paths=()
cleanup() {
  local path
  for path in "${cleanup_paths[@]:-}"; do
    cleanup_temp_file "${path}"
  done
}
trap cleanup EXIT

main() {
  ensure_repo_layout
  create_local_dirs
  ensure_command curl
  ensure_command sha256sum
  ensure_command awk
  ensure_command grep

  local image_path sums_path signature_path metadata_path partial_image partial_sums partial_signature release_page release_stamp header_file etag last_modified
  image_path="${IMAGES_DIR}/${DEFAULT_IMAGE_FILENAME}"
  sums_path="${image_path}.SHA256SUMS"
  signature_path="${image_path}.SHA256SUMS.gpg"
  metadata_path="${image_path}.metadata.json"
  partial_image="${image_path}.partial"
  partial_sums="${sums_path}.partial"
  partial_signature="${signature_path}.partial"
  header_file="$(mktemp)"
  cleanup_paths=("${partial_image}" "${partial_sums}" "${partial_signature}" "${header_file}")

  if [[ "${FORCE_REFRESH}" -eq 0 && -f "${image_path}" && -f "${sums_path}" && -f "${signature_path}" ]]; then
    if "${SCRIPT_DIR}/verify-image.sh" >/dev/null 2>&1; then
      log "Verified cached image already present: ${image_path}"
      exit 0
    fi
    warn "Existing image cache is invalid; refreshing it safely."
  fi

  log "Downloading official checksum manifest from ${DEFAULT_SUMS_URL}"
  curl --fail --location --silent --show-error "${DEFAULT_SUMS_URL}" -o "${partial_sums}"
  mv -- "${partial_sums}" "${sums_path}"

  log "Downloading detached signature for the checksum manifest from ${DEFAULT_SUMS_SIGNATURE_URL}"
  curl --fail --location --silent --show-error "${DEFAULT_SUMS_SIGNATURE_URL}" -o "${partial_signature}"
  mv -- "${partial_signature}" "${signature_path}"

  log "Downloading official Ubuntu cloud image from ${DEFAULT_IMAGE_URL}"
  curl --fail --location --silent --show-error --head "${DEFAULT_IMAGE_URL}" -o "${header_file}"
  curl --fail --location --silent --show-error "${DEFAULT_IMAGE_URL}" -o "${partial_image}"

  local expected_sum actual_sum
  local -a manifest_entry=()
  mapfile -t manifest_entry < <(find_sha256_manifest_entry "${sums_path}" "${DEFAULT_IMAGE_FILENAME}") \
    || die "Could not find a valid SHA256SUMS entry for ${DEFAULT_IMAGE_FILENAME} in ${sums_path}"
  [[ ${#manifest_entry[@]} -eq 2 ]] || die "Invalid checksum parser result for ${DEFAULT_IMAGE_FILENAME}"
  log "Matched checksum manifest entry: ${manifest_entry[0]}"
  expected_sum="${manifest_entry[1]}"
  log "Extracted checksum: ${expected_sum}"
  actual_sum="$(sha256sum "${partial_image}" | awk '{print $1}')"
  [[ "${expected_sum}" == "${actual_sum}" ]] || die "Checksum mismatch for downloaded image."

  mv -- "${partial_image}" "${image_path}"
  cleanup_paths=("${partial_sums}" "${partial_signature}" "${header_file}")

  release_page="$(curl --fail --location --silent --show-error "${DEFAULT_IMAGE_RELEASE_DIR_URL}")"
  release_stamp="$(grep -oE 'release \[[0-9]{8}\]' <<<"${release_page}" | head -n 1 | tr -dc '0-9' || true)"
  etag="$(awk -F': ' 'tolower($1)=="etag" {gsub(/\r/, "", $2); print $2; exit}' "${header_file}" || true)"
  last_modified="$(awk -F': ' 'tolower($1)=="last-modified" {gsub(/\r/, "", $2); print $2; exit}' "${header_file}" || true)"

  python3 - "${metadata_path}" "${release_stamp:-}" "${etag:-}" "${last_modified:-}" "${actual_sum}" \
    "${DEFAULT_IMAGE_RELEASE_DIR_URL}" "${DEFAULT_IMAGE_URL}" "${DEFAULT_SUMS_URL}" "${DEFAULT_SUMS_SIGNATURE_URL}" \
    "${DEFAULT_IMAGE_FILENAME}" "${DEFAULT_IMAGE_RELEASE}" "${DEFAULT_IMAGE_CODENAME}" "${DEFAULT_IMAGE_ARCH}" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    metadata_path,
    release_stamp,
    etag,
    last_modified,
    actual_sum,
    release_directory_url,
    source_url,
    checksum_manifest_url,
    checksum_signature_url,
    image_filename,
    release,
    codename,
    architecture,
) = sys.argv[1:]
metadata = {
    "source_channel": "released",
    "source_is_daily": False,
    "source_is_immutable_by_filename": False,
    "release_directory_url": release_directory_url,
    "source_url": source_url,
    "checksum_manifest_url": checksum_manifest_url,
    "checksum_signature_url": checksum_signature_url,
    "image_filename": image_filename,
    "release": release,
    "codename": codename,
    "architecture": architecture,
    "release_stamp": release_stamp or None,
    "sha256": actual_sum,
    "http_etag": etag or None,
    "http_last_modified": last_modified or None,
    "downloaded_at": datetime.now(timezone.utc).isoformat(),
}
with open(metadata_path, "w", encoding="utf-8") as fh:
    json.dump(metadata, fh, indent=2)
    fh.write("\n")
PY

  log "Cached and verified Ubuntu image: ${image_path}"
}

main "$@"
