#!/usr/bin/env bash
set -Eeuo pipefail

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${COMMON_DIR}/.." && pwd)"
XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
PROJECT_SLUG="kvm-disposable-ubuntu"
STATE_DIR="${XDG_STATE_HOME}/${PROJECT_SLUG}"
DATA_DIR="${XDG_DATA_HOME}/${PROJECT_SLUG}"
MANIFEST_PATH="${STATE_DIR}/install-manifest.json"
GROUP_REFRESH_MARKER="${STATE_DIR}/session-group-refresh-required"
CACHE_DIR="${REPO_ROOT}/.cache"
TMP_DIR="${REPO_ROOT}/.tmp"
DIST_DIR="${REPO_ROOT}/dist"
IMAGES_DIR="${REPO_ROOT}/images"
TERRAFORM_DIR="${REPO_ROOT}/terraform"
DEFAULT_LIBVIRT_POOL_PARENT="/var/lib/libvirt/images"
DEFAULT_LIBVIRT_POOL_PATH="${DEFAULT_LIBVIRT_POOL_PARENT}/${PROJECT_SLUG}"
DEFAULT_IMAGE_RELEASE="26.04"
DEFAULT_IMAGE_CODENAME="resolute"
DEFAULT_IMAGE_ARCH="amd64"
DEFAULT_IMAGE_FILENAME="ubuntu-${DEFAULT_IMAGE_RELEASE}-server-cloudimg-${DEFAULT_IMAGE_ARCH}.img"
DEFAULT_IMAGE_RELEASE_DIR_URL="https://cloud-images.ubuntu.com/releases/${DEFAULT_IMAGE_CODENAME}/release/"
DEFAULT_IMAGE_URL="${DEFAULT_IMAGE_RELEASE_DIR_URL}${DEFAULT_IMAGE_FILENAME}"
DEFAULT_SUMS_URL="${DEFAULT_IMAGE_RELEASE_DIR_URL}SHA256SUMS"
DEFAULT_SUMS_SIGNATURE_URL="${DEFAULT_IMAGE_RELEASE_DIR_URL}SHA256SUMS.gpg"
UBUNTU_CLOUD_IMAGE_SIGNING_KEY_FINGERPRINT="D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81"
DEFAULT_PROVIDER_VERSION="0.9.9"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup_temp_file() {
  local tmp_path="${1:-}"
  if [[ -n "${tmp_path}" && -f "${tmp_path}" ]]; then
    rm -f -- "${tmp_path}"
  fi
}

ensure_command() {
  local command_name="${1:?command name required}"
  command -v "${command_name}" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
}

ensure_repo_layout() {
  [[ -d "${IMAGES_DIR}" ]] || die "Expected images directory missing: ${IMAGES_DIR}"
  [[ -d "${TERRAFORM_DIR}" ]] || die "Expected terraform directory missing: ${TERRAFORM_DIR}"
}

create_local_dirs() {
  ensure_private_dir "${STATE_DIR}"
  mkdir -p -- "${CACHE_DIR}" "${TMP_DIR}" "${DIST_DIR}"
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
}

host_architecture() {
  uname -m
}

repo_realpath() {
  local target="${1:?path required}"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "${target}"
  else
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${target}"
  fi
}

path_owner_group_mode() {
  local target="${1:?path required}"
  stat -Lc 'owner=%U group=%G mode=%a path=%n' "${target}"
}

ensure_within_repo() {
  local target="${1:?path required}"
  local resolved_root resolved_target
  resolved_root="$(repo_realpath "${REPO_ROOT}")"
  resolved_target="$(repo_realpath "${target}")"
  [[ "${resolved_target}" == "${resolved_root}" || "${resolved_target}" == "${resolved_root}/"* ]] || die "Refusing to operate on path outside repository: ${target}"
}

safe_rm_path() {
  local target="${1:?path required}"
  ensure_within_repo "${target}"
  if [[ -e "${target}" || -L "${target}" ]]; then
    rm -rf -- "${target}"
  fi
}

manifest_init() {
  create_local_dirs
  if [[ ! -f "${MANIFEST_PATH}" ]]; then
    cat >"${MANIFEST_PATH}" <<'EOF'
{
  "project": "kvm-disposable-ubuntu",
  "packages_installed": [],
  "packages_preexisting": [],
  "apt_sources_created": [],
  "keyring_files_created": [],
  "group_membership_changes": [],
  "services_enabled": [],
  "directories_created": [],
  "terraform_pool_directories": [],
  "libvirt_pool_parent_state": null,
  "detected_libvirt_qemu_user": null,
  "detected_libvirt_qemu_uid": null,
  "detected_kvm_group": null,
  "detected_kvm_gid": null,
  "caches_created": [],
  "selected_image_version": null,
  "selected_provider_version": null,
  "updated_at": null
}
EOF
  fi
}

manifest_require_editor() {
  if ! command -v jq >/dev/null 2>&1; then
    ensure_command python3
  fi
  manifest_init
}

manifest_add_unique_string() {
  local key="${1:?manifest key required}"
  local value="${2:?manifest value required}"
  manifest_require_editor
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'cleanup_temp_file "${tmp_file}"' RETURN
  if command -v jq >/dev/null 2>&1; then
    jq --arg key "${key}" --arg value "${value}" '
      .[$key] = ((.[$key] // []) + [$value] | unique)
      | .updated_at = (now | todate)
    ' "${MANIFEST_PATH}" >"${tmp_file}"
  else
    python3 - "${MANIFEST_PATH}" "${tmp_file}" "${key}" "${value}" <<'PY'
import json
import sys
from datetime import datetime, timezone

src, dst, key, value = sys.argv[1:]
with open(src, "r", encoding="utf-8") as fh:
    data = json.load(fh)
items = list(data.get(key, []))
if value not in items:
    items.append(value)
data[key] = items
data["updated_at"] = datetime.now(timezone.utc).isoformat()
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=False)
    fh.write("\n")
PY
  fi
  mv -- "${tmp_file}" "${MANIFEST_PATH}"
  trap - RETURN
}

manifest_set_value() {
  local key="${1:?manifest key required}"
  local value="${2:?manifest value required}"
  manifest_require_editor
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'cleanup_temp_file "${tmp_file}"' RETURN
  if command -v jq >/dev/null 2>&1; then
    jq --arg key "${key}" --arg value "${value}" '
      .[$key] = $value
      | .updated_at = (now | todate)
    ' "${MANIFEST_PATH}" >"${tmp_file}"
  else
    python3 - "${MANIFEST_PATH}" "${tmp_file}" "${key}" "${value}" <<'PY'
import json
import sys
from datetime import datetime, timezone

src, dst, key, value = sys.argv[1:]
with open(src, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data[key] = value
data["updated_at"] = datetime.now(timezone.utc).isoformat()
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=False)
    fh.write("\n")
PY
  fi
  mv -- "${tmp_file}" "${MANIFEST_PATH}"
  trap - RETURN
}

record_cache_dir() {
  local path="${1:?cache path required}"
  mkdir -p -- "${path}"
  manifest_add_unique_string "caches_created" "${path}"
}

record_terraform_pool_directory() {
  local path="${1:?Terraform pool path required}"
  manifest_add_unique_string "terraform_pool_directories" "${path}"
}

current_user_name() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
  else
    id -un
  fi
}

current_user_home() {
  local user_name
  user_name="$(current_user_name)"
  getent passwd "${user_name}" | cut -d: -f6
}

user_uid() {
  local user_name="${1:?user required}"
  getent passwd "${user_name}" | cut -d: -f3
}

group_gid() {
  local group_name="${1:?group required}"
  getent group "${group_name}" | cut -d: -f3
}

current_user_in_group() {
  local user_name="${1:?user required}"
  local group_name="${2:?group required}"
  id -nG "${user_name}" | tr ' ' '\n' | grep -Fxq "${group_name}"
}

current_session_in_group() {
  local group_name="${1:?group required}"
  id -Gn | tr ' ' '\n' | grep -Fxq "${group_name}"
}

confirm() {
  local prompt="${1:?prompt required}"
  local response
  read -r -p "${prompt} [y/N]: " response
  [[ "${response}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

terraform_state_present() {
  [[ -f "${TERRAFORM_DIR}/terraform.tfstate" || -f "${TERRAFORM_DIR}/terraform.tfstate.backup" ]]
}

terraform_lock_file_path() {
  printf '%s\n' "${TERRAFORM_DIR}/.terraform.lock.hcl"
}

terraform_available() {
  command -v terraform >/dev/null 2>&1
}

ubuntu_libvirt_qemu_user() {
  local configured_user=""
  if [[ -r /etc/libvirt/qemu.conf ]]; then
    configured_user="$(awk -F'"' '/^[[:space:]]*user[[:space:]]*=/ {print $2; exit}' /etc/libvirt/qemu.conf)"
  fi

  if [[ -n "${configured_user}" ]]; then
    getent passwd "${configured_user}" >/dev/null 2>&1 || die "Configured libvirt QEMU user does not exist: ${configured_user}"
    printf '%s\n' "${configured_user}"
    return 0
  fi

  getent passwd libvirt-qemu >/dev/null 2>&1 || die "Expected Ubuntu libvirt QEMU user libvirt-qemu was not found."
  printf '%s\n' "libvirt-qemu"
}

ubuntu_kvm_group() {
  getent group kvm >/dev/null 2>&1 || die "Expected Ubuntu KVM group kvm was not found."
  printf '%s\n' "kvm"
}

ensure_user_in_group() {
  local user_name="${1:?user required}"
  local group_name="${2:?group required}"
  id -nG "${user_name}" | tr ' ' '\n' | grep -Fxq "${group_name}" \
    || die "User ${user_name} is not a member of required group ${group_name}."
}

record_libvirt_runtime_identity() {
  local qemu_user kvm_group qemu_uid kvm_gid
  qemu_user="$(ubuntu_libvirt_qemu_user)"
  kvm_group="$(ubuntu_kvm_group)"
  ensure_user_in_group "${qemu_user}" "${kvm_group}"

  qemu_uid="$(user_uid "${qemu_user}")"
  kvm_gid="$(group_gid "${kvm_group}")"
  [[ -n "${qemu_uid}" ]] || die "Could not resolve UID for ${qemu_user}"
  [[ -n "${kvm_gid}" ]] || die "Could not resolve GID for ${kvm_group}"

  manifest_set_value "detected_libvirt_qemu_user" "${qemu_user}"
  manifest_set_value "detected_libvirt_qemu_uid" "${qemu_uid}"
  manifest_set_value "detected_kvm_group" "${kvm_group}"
  manifest_set_value "detected_kvm_gid" "${kvm_gid}"
}

terraform_configured_pool_path() {
  local console_output resolved_path
  ensure_command terraform

  if ! console_output="$(printf 'local.pool_path\n' | terraform -chdir="${TERRAFORM_DIR}" console -no-color 2>/dev/null)"; then
    terraform -chdir="${TERRAFORM_DIR}" init -backend=false >/dev/null
    console_output="$(printf 'local.pool_path\n' | terraform -chdir="${TERRAFORM_DIR}" console -no-color 2>/dev/null)" \
      || die "Could not resolve local.pool_path from the Terraform configuration."
  fi

  resolved_path="${console_output##*$'\n'}"
  resolved_path="${resolved_path%$'\r'}"
  resolved_path="${resolved_path#\"}"
  resolved_path="${resolved_path%\"}"

  [[ -n "${resolved_path}" ]] || die "Terraform local.pool_path resolved to an empty value."
  [[ "${resolved_path}" = /* ]] || die "Terraform local.pool_path must resolve to an absolute path, got: ${resolved_path}"

  printf '%s\n' "${resolved_path}"
}

virsh_available() {
  command -v virsh >/dev/null 2>&1
}

ensure_private_dir() {
  local dir_path="${1:?directory path required}"
  local mode
  [[ ! -e "${dir_path}" || -d "${dir_path}" ]] || die "Expected directory path but found non-directory: ${dir_path}"
  mkdir -p -- "${dir_path}"
  chmod go-rwx -- "${dir_path}"
  mode="$(stat -c '%a' "${dir_path}")"
  [[ "${mode: -2}" == "00" ]] || die "Failed to secure directory permissions for ${dir_path}; current mode is ${mode}"
}

ubuntu_cloud_image_gnupg_home() {
  printf '%s\n' "${STATE_DIR}/gnupg/ubuntu-cloud-images"
}

find_sha256_manifest_entry() {
  local sums_path="${1:?checksum manifest path required}"
  local file_name="${2:?filename required}"
  local line

  [[ -f "${sums_path}" ]] || die "Checksum manifest missing: ${sums_path}"

  while IFS= read -r line; do
    [[ "${line}" =~ ^([[:xdigit:]]{64})[[:space:]]+\*?(.*)$ ]] || continue
    [[ "${BASH_REMATCH[2]}" == "${file_name}" ]] || continue
    printf '%s\n%s\n' "${line}" "${BASH_REMATCH[1]}"
    return 0
  done < "${sums_path}"

  return 1
}

jq_get_manifest_array() {
  local key="${1:?manifest key required}"
  if [[ -f "${MANIFEST_PATH}" ]] && command -v jq >/dev/null 2>&1; then
    jq -r --arg key "${key}" '.[$key] // [] | .[]' "${MANIFEST_PATH}"
  fi
}

default_vm_name() {
  printf '%s\n' "disposable-ubuntu"
}

terraform_output_raw() {
  local output_name="${1:?output name required}"
  terraform -chdir="${TERRAFORM_DIR}" output -raw "${output_name}"
}

ssh_options() {
  printf '%s\n' "-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${CACHE_DIR}/known_hosts"
}

mark_group_refresh_required() {
  create_local_dirs
  : >"${GROUP_REFRESH_MARKER}"
}

clear_group_refresh_marker() {
  if [[ -f "${GROUP_REFRESH_MARKER}" ]]; then
    rm -f -- "${GROUP_REFRESH_MARKER}"
  fi
}

group_refresh_required() {
  [[ -f "${GROUP_REFRESH_MARKER}" ]]
}
