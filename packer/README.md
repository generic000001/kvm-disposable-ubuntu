# Optional golden image workflow

The default repository mode is **image-cached mode**:

1. cache the official Ubuntu cloud image locally;
2. mirror the Terraform provider locally;
3. let cloud-init install Docker and the guest agent during first boot.

That mode keeps the workflow simple but does **not** guarantee guest package
installation without internet access.

For **fully prepared mode**, build or import a locally prepared golden image
that already contains Docker, Docker Compose support, and any other guest
packages you require. This repository does not make Packer mandatory because it
would add another host dependency to the common path, but this directory is the
place to keep an optional Packer workflow if you decide to adopt one.

When you introduce a Packer build, keep these controls:

- start from a verified official Ubuntu image from `../images/`;
- install only the packages required inside the guest;
- clear cloud-init state before capture;
- do not store secrets or host-specific SSH keys in the image;
- write the final image back to `../images/` with a distinct golden-image name;
- set `install_docker = false` and `install_qemu_guest_agent = false` if the
  image already contains those packages.
