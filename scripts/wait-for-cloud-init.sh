#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

STATUS_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --status-only)
      STATUS_ONLY=1
      ;;
    *)
      die "Unsupported argument: ${arg}"
      ;;
  esac
done

main() {
  ensure_command ssh
  local ip_address ssh_user ssh_opts attempt max_attempts=24
  ip_address="$("${SCRIPT_DIR}/discover-vm-ip.sh")"
  ssh_user="$(terraform_output_raw ssh_username 2>/dev/null || printf '%s\n' ubuntu)"
  ssh_opts="$(ssh_options)"

  if [[ "${STATUS_ONLY}" -eq 1 ]]; then
    ssh ${ssh_opts} "${ssh_user}@${ip_address}" 'cloud-init status --long || sudo cloud-init status --long'
    exit 0
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt += 1)); do
    if ssh ${ssh_opts} "${ssh_user}@${ip_address}" 'cloud-init status --wait >/tmp/cloud-init-wait.log 2>&1 || sudo cloud-init status --wait >/tmp/cloud-init-wait.log 2>&1'; then
      log "cloud-init completed successfully on ${ip_address}"
      exit 0
    fi
    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      warn "cloud-init has not completed yet (attempt ${attempt}/${max_attempts}); retrying in 10s."
      sleep 10
    fi
  done

  ssh ${ssh_opts} "${ssh_user}@${ip_address}" 'sudo cloud-init status --long || true; sudo tail -n 100 /var/log/cloud-init.log /var/log/cloud-init-output.log 2>/dev/null || true' || true
  die "cloud-init did not complete successfully within the allowed retry window."
}

main "$@"
