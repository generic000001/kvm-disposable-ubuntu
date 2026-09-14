#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

main() {
  ensure_repo_layout
  ensure_command python3

  python3 - "${TERRAFORM_DIR}/terraform.tfvars" "${TERRAFORM_DIR}" "${DEFAULT_IMAGE_FILENAME}" <<'PY'
import os
import pathlib
import re
import sys

tfvars_path, terraform_dir, default_filename = sys.argv[1:]
configured = f"../images/{default_filename}"

if pathlib.Path(tfvars_path).is_file():
    pattern = re.compile(r"^\s*ubuntu_image_path\s*=\s*(.+?)\s*$")
    for raw_line in pathlib.Path(tfvars_path).read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        match = pattern.match(line)
        if not match:
            continue
        configured = match.group(1).strip()
        if configured.startswith('"') and configured.endswith('"'):
            configured = configured[1:-1]
        break

resolved = pathlib.Path(os.path.expanduser(configured))
if not resolved.is_absolute():
    resolved = pathlib.Path(terraform_dir) / resolved
resolved = resolved.resolve()

if resolved.is_file():
    sys.exit(0)

message = (f"Ubuntu image cache not found:\n\n{resolved}\n\n"
      "Git worktrees do not share downloaded image caches.\n"
      "This worktree does not currently contain the required Ubuntu image.\n\n")

worktree_root = pathlib.Path(terraform_dir).parent
sibling_root = worktree_root.parent
has_sibling_cache = any(
    candidate.is_dir()
    and candidate != worktree_root
    and (candidate / "images" / resolved.name).is_file()
    for candidate in sibling_root.iterdir()
)
if has_sibling_cache:
    message += ("A cached image was found in another worktree.\n"
                "Consider copying it instead of downloading again.\n\n")

message += ("To restore the image cache run:\n\n"
            "make download-image\n"
            "make verify-image\n\n"
            "Or:\n\n"
            "make prepare-offline")
print(message, file=sys.stderr)
sys.exit(1)
PY
}

main "$@"
