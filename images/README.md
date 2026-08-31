# Image cache

This directory intentionally tracks only documentation and placeholder files.

Runtime commands store the verified Ubuntu source image, checksum manifest, and
provenance metadata here so that:

1. `terraform apply` never downloads the guest image directly.
2. the canonical image cache survives normal VM destruction;
3. the image can be reviewed, refreshed, or purged explicitly.

Expected runtime artefacts:

- `ubuntu-26.04-server-cloudimg-amd64.img`
- `ubuntu-26.04-server-cloudimg-amd64.img.SHA256SUMS`
- `ubuntu-26.04-server-cloudimg-amd64.img.metadata.json`
- optional locally prepared golden images such as
  `ubuntu-26.04-docker-golden-amd64.qcow2`

These binaries are ignored by Git because they are large, change over time, and
belong in a local cache or separately distributed offline bundle rather than in
normal Git history.
