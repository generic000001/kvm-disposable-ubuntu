#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p -- "${FAKE_BIN}"

cat >"${FAKE_BIN}/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ " $* " == *" console "* ]]; then
  IFS= read -r expression
  case "${expression}" in
    local.pool_name) printf '"kvm-disposable-ubuntu-pool"\n' ;;
    local.pool_path) printf '"/var/lib/libvirt/images/kvm-disposable-ubuntu"\n' ;;
    var.vm_name) printf '"disposable-ubuntu"\n' ;;
    local.managed_volume_permissions_revision) printf '"test-revision"\n' ;;
    local.base_volume_name) printf '"disposable-ubuntu-base.qcow2"\n' ;;
    local.guest_volume_name) printf '"disposable-ubuntu-overlay.qcow2"\n' ;;
    local.seed_volume_name) printf '"disposable-ubuntu-cloudinit.iso"\n' ;;
    *) printf 'unexpected expression: %s\n' "${expression}" >&2; exit 1 ;;
  esac
  exit 0
fi

if [[ "${*: -2}" == "state list" ]]; then
  exit 0
fi

if [[ "${*: -1}" == "apply" ]]; then
  : >"${TEST_ROOT}/terraform-apply-started"
fi
EOF
chmod +x "${FAKE_BIN}/terraform"

cat >"${FAKE_BIN}/virsh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ " $* " == *" pool-info kvm-disposable-ubuntu-pool "* ]]; then
    printf 'Name: kvm-disposable-ubuntu-pool\nState: running\n'
elif [[ " $* " == *" dominfo disposable-ubuntu "* ]]; then
    printf 'Name: disposable-ubuntu\nState: shut off\n'
elif [[ " $* " == *" vol-info "* ]]; then
    printf 'Name: deployment-volume\nType: file\n'
else
    exit 1
fi
EOF
chmod +x "${FAKE_BIN}/virsh"

set +e
(
  cd -- "${REPO_ROOT}"
  PATH="${FAKE_BIN}:${PATH}" make create >"${TEST_ROOT}/output" 2>&1
)
status=$?
set -e

[[ "${status}" -ne 0 ]] || {
  cat "${TEST_ROOT}/output" >&2
  printf 'Expected make create to reject an existing unmanaged pool.\n' >&2
  exit 1
}
grep -Fq "Refusing to create" "${TEST_ROOT}/output" || {
  cat "${TEST_ROOT}/output" >&2
  printf 'Expected ownership refusal in make create output.\n' >&2
  exit 1
}
[[ ! -e "${TEST_ROOT}/terraform-apply-started" ]] || {
  printf 'Terraform apply started before ownership preflight rejected the deployment.\n' >&2
  exit 1
}

printf 'create ownership guard regression passed\n'
