---
layout: post
title: "Traditional RHEL vs Image Mode: Deploying and Patching a Webserver"
date: 2026-07-21
---

There are two ways to run Red Hat Enterprise Linux. Traditional RHEL installs packages onto a mutable filesystem — the model that has worked for decades. Image Mode RHEL treats the entire operating system as a container image — you build it, test it, and deploy it as a single artifact. Both use the same kernel, the same RPM packages, and the same hardware drivers. The difference is how you manage them after day one. This is a quick why and how-to for seeing that difference firsthand by deploying Apache httpd on both, comparing what each system looks like, and then patching a real CVE on each.

## Why This Matters

Every RHEL system starts clean. The trouble is what happens over the following months. On a traditional system, someone runs `dnf install` to add a debugging tool. A colleague applies a patch to one node but not the others. A firewall rule gets added by hand. Six months in, no two nodes in the fleet look exactly the same, and nobody can say with certainty what changed or when. This is configuration drift, and it is not a failure of discipline — it is a property of the model. When the filesystem is mutable and every change happens in place, drift is the default outcome.

Patching on a traditional system is a per-node operation. You run `dnf update` on each machine, and each machine applies the update to its own unique state. If the update fails or causes a regression, rolling back means running `dnf history undo`, which attempts to downgrade individual packages — a process that can fail if dependency relationships have shifted since the original install. There is no guarantee that a rollback returns the system to its previous state.

Image Mode changes the unit of management from individual packages to a complete OS image. You define what goes into the system in a Containerfile, build it with `podman build`, and every system running that image version is identical — same packages, same configuration, same filesystem content. When a CVE drops, you rebuild the image, test it once, and roll it out. Every node that pulls the new image gets exactly the same fix. If something breaks, `bootc rollback` atomically switches back to the previous image. The rollback is not an attempt — it is a swap between two known-good filesystem trees.

This is not about one approach being universally better. Traditional RHEL gives you full runtime flexibility — you can install, configure, and modify anything at any time. Image Mode trades that flexibility for predictability and fleet consistency. Understanding the practical differences helps you choose the right model for your workload.

---

## The Steps

1. Build an Image Mode RHEL system with httpd using a Containerfile and bootc-image-builder
2. Build a stripped-down Image Mode variant with unnecessary packages removed
3. Set up httpd on a traditional RHEL system
4. Compare all three systems: package counts, running services, open ports, and filesystem model
5. Patch CVE-2025-23048 (httpd mod_ssl access control bypass) across all three approaches
6. Test rollback

---

## How To Do It

### Step 1: Build the Image Mode RHEL System

This step builds a bootable RHEL 9 image with httpd baked in, converts it to a QCOW2 disk image, and boots it in UTM.

#### Prerequisites

You need Podman installed and authenticated to the Red Hat container registry. On macOS, the Podman machine must be running in rootful mode because bootc-image-builder requires privileged access to build disk images.

```bash
podman machine stop
podman machine set --rootful
podman machine start
```

Log in to the Red Hat registry. This requires a Red Hat account (a free developer account works):

```bash
podman login registry.redhat.io
```

Verify the login succeeded:

```bash
podman login --get-login registry.redhat.io
```

You should see your username printed.

#### Create the Test Page

This is the HTML page httpd will serve. It is intentionally simple — just enough to confirm the server is running.

📄 [1-index.html](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/rhel-traditional-vs-image-mode/1-index.html)

```html
<!DOCTYPE html>
<html>
<head><title>Image Mode RHEL - httpd test</title></head>
<body>
<h1>Hello from Image Mode RHEL</h1>
<p>If you can see this page, httpd is running on an Image Mode RHEL system.</p>
</body>
</html>
```

#### Create the Containerfile

This Containerfile defines the entire operating system. Every package, every service, every configuration file is declared here. When you build this image, you get a complete bootable RHEL system with httpd ready to serve traffic.

📄 [2-Containerfile](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/rhel-traditional-vs-image-mode/2-Containerfile)

```bash
podman build -t localhost/rhel-httpd-bootc:latest -f 2-Containerfile docs/posts/rhel-traditional-vs-image-mode/
```

```dockerfile
FROM registry.redhat.io/rhel9/rhel-bootc:9.8

RUN dnf -y install httpd firewalld && \
    systemctl enable httpd firewalld && \
    mv /var/www /usr/share/www && \
    sed -i 's,/var/www,/usr/share/www,' /etc/httpd/conf/httpd.conf && \
    rm -rf /usr/share/httpd/noindex && \
    firewall-offline-cmd --service=http && \
    dnf clean all

COPY 1-index.html /usr/share/www/html/index.html

RUN bootc container lint
```

Here is what each section does:

**`FROM registry.redhat.io/rhel9/rhel-bootc:9.8`** — The base image. Unlike a standard UBI image, this one includes the Linux kernel, bootloader, firmware, initramfs, and systemd — everything needed to boot a bare-metal or virtual machine. It is a full operating system in a container image.

**`dnf -y install httpd firewalld`** — Installs Apache httpd, firewalld, and their dependencies. These are the only packages we are adding to the base image.

**`systemctl enable httpd firewalld`** — Enables both systemd units so they start automatically on boot. This works because the bootc base image includes a full systemd init system.

**`mv /var/www /usr/share/www`** — Moves the web content directory from `/var/www` to `/usr/share/www`. In Image Mode, the `/usr` filesystem is mounted read-only and is part of the immutable OS image. Content under `/var` is mutable and persists across updates — but web content should be part of the image, not local state. Moving it to `/usr/share/www` ensures the content updates atomically with the rest of the OS image.

**`sed -i 's,/var/www,/usr/share/www,' /etc/httpd/conf/httpd.conf`** — Updates the httpd configuration to reference the new content path.

**`rm -rf /usr/share/httpd/noindex`** — Removes the default "Test Page" that httpd ships. We are replacing it with our own index page.

**`firewall-offline-cmd --service=http`** — Opens port 80 in the firewall configuration. This uses `firewall-offline-cmd` instead of `firewall-cmd` because the firewalld daemon is not running during image builds — `firewall-offline-cmd` writes directly to the configuration files. On the traditional RHEL side, you run `firewall-cmd` against the live daemon; here, the equivalent work happens at build time.

**`dnf clean all`** — Clears the DNF cache to reduce image size. Cached metadata is not needed in a bootable image.

**`COPY 1-index.html /usr/share/www/html/index.html`** — Copies our test page into the image. This page is now part of the immutable OS — it will be the same on every system that runs this image.

**`RUN bootc container lint`** — Runs the bootc linter, which checks that the image meets the requirements for a bootable system (kernel present, systemd configured correctly, filesystem layout valid). If this step passes, the image is safe to convert to a disk image.

Verify the build succeeded:

```bash
podman images localhost/rhel-httpd-bootc
```

You should see the image listed with a recent timestamp.

#### Create the User Configuration

bootc-image-builder uses a TOML configuration file to set up user accounts on the deployed system. Without this, you would have no way to log in after boot.

📄 [3-config.toml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/rhel-traditional-vs-image-mode/3-config.toml)

```toml
[[customizations.user]]
name = "admin"
password = "changeme"
groups = ["wheel"]
```

This creates a user named `admin` with `sudo` access (via the `wheel` group). Change the password to something appropriate for your environment. In production, you would use an SSH public key instead of a password — add a `key` field with your public key string.

#### Build the QCOW2 Disk Image

This step converts the container image into a bootable QCOW2 disk image using bootc-image-builder. The builder defaults to pulling from local container storage, so it will find the image you just built without needing a remote registry.

```bash
mkdir -p output

podman run --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v ./3-config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhel-httpd-bootc:latest
```

Here is what each flag does:

**`--privileged`** — bootc-image-builder needs privileged access to create filesystem images, configure SELinux labels, and set up the bootloader.

**`--security-opt label=type:unconfined_t`** — Disables SELinux confinement for the builder container. The builder needs to manipulate filesystem labels that a confined container cannot access.

**`-v ./3-config.toml:/config.toml:ro`** — Mounts the user configuration file into the builder container at the path it expects.

**`-v ./output:/output`** — Mounts the output directory. The finished QCOW2 file will appear here.

**`-v /var/lib/containers/storage:/var/lib/containers/storage`** — Shares the local container storage with the builder so it can access the image you built in the previous step. The builder defaults to local storage, so it will find `localhost/rhel-httpd-bootc:latest` without needing a `--local` flag.

**`--type qcow2`** — Specifies the output format. Other options include `raw`, `vmdk`, `ami`, and `iso`.

This step takes several minutes. When it completes, verify the output:

```bash
ls -lh output/qcow2/disk.qcow2
```

You should see a QCOW2 file, typically between 2-4 GB.

> In production, you would push your bootc image to a container registry (Quay, Harbor, or any OCI-compliant registry) and have bootc-image-builder pull from there. The `--local` flag is a convenience for development and testing.

#### Import into UTM and Boot

1. Open UTM and create a new virtual machine
2. Select **Virtualize** (not Emulate — you are on Apple Silicon and the image is aarch64)
3. Choose **Linux** as the operating system
4. Skip the boot ISO — instead, go to the disk settings and select **Import** to use the QCOW2 file from `output/qcow2/disk.qcow2`
5. Allocate at least 2 GB of RAM and 2 CPU cores
6. Start the VM

Log in with the credentials from `3-config.toml` (username: `admin`, password: `changeme`).

Verify httpd is running:

```bash
systemctl status httpd
```

The service should show `active (running)`.

Verify the test page:

```bash
curl http://localhost
```

You should see the HTML from `1-index.html`.

Check the bootc status to see the running image:

```bash
sudo bootc status
```

This shows the currently booted image, the image reference, and the digest. Note there is no "rollback" image listed yet — that column populates after the first upgrade.

---

### Step 2: Build the Minimal Image Mode Variant

The standard bootc base image includes packages for enterprise identity (SSSD/AD/Kerberos), storage management (LVM, mdadm, cryptsetup), and general-purpose tools (nano, lsof, bind-utils) that a dedicated httpd server does not need. Stripping these reduces the installed package count from 469 to 433 — fewer binaries, fewer potential CVEs, less to scan and validate.

📄 [4-Containerfile.minimal](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/rhel-traditional-vs-image-mode/4-Containerfile.minimal)

```dockerfile
FROM registry.redhat.io/rhel9/rhel-bootc:9.8

RUN dnf -y install httpd firewalld && \
    dnf -y remove --noautoremove \
      toolbox \
      sssd-ad sssd-ipa sssd-krb5 sssd-krb5-common sssd-ldap sssd-common-pac \
      adcli adcli-selinux samba-client-libs samba-common samba-common-libs \
      lvm2 mdadm cryptsetup udisks2 nvme-cli \
      nano socat lsof bind-utils net-tools bash-completion \
      tpm2-tools stalld WALinuxAgent-udev \
      flatpak-session-helper console-login-helper-messages \
      console-login-helper-messages-issuegen \
      console-login-helper-messages-profile \
      dnf-bootc criu && \
    systemctl enable httpd firewalld && \
    mv /var/www /usr/share/www && \
    sed -i 's,/var/www,/usr/share/www,' /etc/httpd/conf/httpd.conf && \
    rm -rf /usr/share/httpd/noindex && \
    firewall-offline-cmd --service=http && \
    dnf clean all

COPY 1-index.html /usr/share/www/html/index.html

RUN bootc container lint
```

The key difference from the standard Containerfile is the `dnf -y remove --noautoremove` step. The `--noautoremove` flag prevents DNF from cascading the removal to packages that depend on the ones being removed — without it, removing `criu` would also remove `podman`, which would remove `bootc`, which would break the entire image mode runtime.

Here is what gets removed and why:

**Enterprise identity (SSSD, AD, Samba)** — Unless this server joins an Active Directory domain or authenticates against an LDAP/Kerberos realm, these are dead weight. If you need AD-joined httpd, keep these.

**Storage stack (LVM, mdadm, cryptsetup, NVMe)** — A single-disk VM serving web pages does not need logical volume management, software RAID, or NVMe tooling. If you are running on complex storage, keep these.

**General-purpose tools (nano, lsof, bind-utils, net-tools, socat, bash-completion)** — Useful for interactive debugging, but on an immutable system you would debug by inspecting the container image, not by SSH'ing into the node. Removing these enforces that discipline.

**Other (toolbox, tpm2-tools, stalld, WALinuxAgent-udev, flatpak-session-helper)** — Toolbox is for container-based development shells. TPM tools are for hardware security modules. Stalld is for real-time workloads. WALinuxAgent is for Azure VMs. None apply to a dedicated httpd server.

What stays: `bootc`, `ostree`, `podman`, and `skopeo` remain so that `bootc upgrade` continues to work. The image can still pull updates from a registry and perform atomic upgrades. If you are willing to give up self-updating (reimaging the disk for every update instead), you could remove these too and drop to around 350 packages.

Build the minimal image:

```bash
podman build -t localhost/rhel-httpd-bootc:minimal -f 4-Containerfile.minimal docs/posts/rhel-traditional-vs-image-mode/
```

Build the QCOW2 the same way as before:

```bash
mkdir -p output

podman run --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v ./3-config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhel-httpd-bootc:minimal
```

Verify the package count:

```bash
podman run --rm localhost/rhel-httpd-bootc:minimal rpm -qa | wc -l
```

You should see 433 packages, down from 469 in the standard build.

---

### Step 3: Set Up httpd on Traditional RHEL

Start with a RHEL 9.8 system. If you do not already have one running, install it from the RHEL 9.8 boot ISO using the standard Anaconda installer. The installation process is the familiar graphical workflow — select your disk, set a root password, choose a minimal install, and let Anaconda lay down the packages. Note the contrast with Image Mode: there is no Anaconda step. The operating system was defined in a Containerfile and built into a disk image before the machine ever booted.

Register the system with your Red Hat subscription:

```bash
sudo subscription-manager register --activationkey=<your-activation-key> --org=<your-org-id>
```

Install httpd:

```bash
sudo dnf install -y httpd
```

Enable and start the service:

```bash
sudo systemctl enable --now httpd
```

Open the firewall for HTTP traffic:

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```

Create a test page so both systems serve the same content:

```bash
sudo tee /var/www/html/index.html > /dev/null << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head><title>Traditional RHEL - httpd test</title></head>
<body>
<h1>Hello from Traditional RHEL</h1>
<p>If you can see this page, httpd is running on a traditional RHEL system.</p>
</body>
</html>
HTMLEOF
```

Verify the service is running:

```bash
systemctl status httpd
```

Verify the test page:

```bash
curl http://localhost
```

You should see the HTML content you just created.

---

### Step 4: Compare All Three Systems

With all three systems running the same workload (httpd serving a test page), run these commands on each to compare their footprints.

#### Package Count

On each system:

```bash
rpm -qa | wc -l
```

The traditional RHEL minimal install with httpd will have significantly more packages than the Image Mode system because the Anaconda minimal install includes packages for the installer, documentation, and general-purpose tools that are not present in the curated bootc base image.

#### Running Services

On each system:

```bash
systemctl list-units --type=service --state=running --no-pager
```

#### Open Ports

On each system:

```bash
sudo ss -tlnp
```

#### Filesystem Model

On the Image Mode system, try modifying a file under `/usr`:

```bash
sudo touch /usr/testfile
```

This will fail with a read-only filesystem error. The `/usr` tree is immutable — it can only be changed by deploying a new image. This is what prevents drift.

On the traditional system, the same command succeeds. Any user with root access can modify any file at any time.

#### Comparison Table

Here are the measured results from all three systems, each running RHEL 9.8 on aarch64 with httpd and firewalld:

| Metric | Traditional RHEL | Image Mode | Image Mode Minimal |
|---|---|---|---|
| Installed packages (`rpm -qa \| wc -l`) | 511 | 469 | 433 |
| Running services | 21 | 17 | 17 |
| Listening ports | 3 (ssh, httpd, rpcbind) | 3 (ssh, httpd, rpcbind) | 3 (ssh, httpd, rpcbind) |
| Filesystem mutability | Fully read-write | `/usr` is read-only | `/usr` is read-only |
| Configuration drift risk | Yes | No | No |
| Package installation at runtime | `dnf install` works | Not supported | Not supported |
| `bootc upgrade` (self-update) | N/A | Yes | Yes |
| AD/Kerberos/LDAP identity | Yes | Yes | No |
| LVM / software RAID / NVMe | Yes | Yes | No |
| Interactive debug tools | Yes | Yes | No |

The traditional system carries 78 more packages than the minimal Image Mode build. That gap is not just count — it is attack surface. The traditional system includes services like `auditd`, `crond`, `rsyslog`, `tuned`, and `gssproxy` that run by default. The standard Image Mode build drops those but still carries enterprise identity, storage management, and diagnostic tools. The minimal build strips everything that a dedicated httpd server does not need.

On a traditional system, that gap widens over time. Every `dnf install` someone runs, every debugging tool left behind, every one-off dependency that never gets removed — the footprint grows. On either Image Mode build, the footprint cannot grow because `/usr` is immutable. The only way to add packages is to rebuild the image, which means the change is intentional, reviewed, and applied identically to every node.

The minimal build makes a deliberate tradeoff: you lose the ability to join an AD domain, manage LVM volumes, or use tools like `lsof` and `dig` when SSH'd into the node. In exchange, you get fewer packages to patch and a smaller surface to secure. For a webserver that authenticates through its application layer and runs on simple storage, that tradeoff is usually worth it.

---

### Step 5: Patch CVE-2025-23048

CVE-2025-23048 is a real vulnerability in Apache httpd's mod_ssl module. It allows a client that is trusted by one virtual host to bypass access controls on a different virtual host through TLS 1.3 session resumption. Red Hat published the fix in advisory [RHSA-2025:15023](https://access.redhat.com/errata/RHSA-2025:15023), updating httpd to version 2.4.62-4.el9_6.4. Both systems in this walkthrough already include the fix because they were built from current RHEL 9.8 packages — but the workflow for how that fix arrived is fundamentally different, and that difference is what matters at scale.

#### Traditional RHEL: Patch In Place

When a CVE advisory drops, the workflow on each traditional RHEL node looks like this:

Check for available security updates:

```bash
sudo dnf updateinfo list --cve CVE-2025-23048
```

This queries the Red Hat CDN for advisories that address the specified CVE. The output shows the advisory ID, severity, and affected package.

Look up the advisory details:

```bash
sudo dnf updateinfo info RHSA-2025:15023
```

Apply the fix:

```bash
sudo dnf update --advisory RHSA-2025:15023 -y
```

Verify the update:

```bash
rpm -q httpd
```

Restart the service to pick up the new binary:

```bash
sudo systemctl restart httpd
```

Confirm the service is healthy:

```bash
systemctl status httpd
curl http://localhost
```

This patched one node. If you have ten nodes, you repeat this on each one. Each node applies the update to its own state independently. There is no guarantee that all ten nodes end up identical — one might have additional packages installed that create a dependency conflict, or a network issue might cause the update to fail partway through on one node. The only way to know all nodes are patched is to check each one.

#### Image Mode: Rebuild and Upgrade

The Image Mode workflow is different. Instead of patching each node, you rebuild the image once and let every node pull the same updated version.

On your build machine (your Mac, not the Image Mode VM), rebuild the bootc image. Because the Containerfile references the `rhel-bootc:9.8` base image and runs `dnf -y install httpd`, rebuilding pulls the latest packages — including any CVE fixes — into the new image.

```bash
podman build --no-cache -t localhost/rhel-httpd-bootc:latest -f 2-Containerfile docs/posts/rhel-traditional-vs-image-mode/
```

The `--no-cache` flag ensures a fresh build that picks up the latest package versions from the RHEL repos.

At this point you have a new image. You can test it locally — run it as a container, verify httpd works, check the package version — before deploying it to any production system. This is the key advantage: you test the fix once, in your build pipeline, and that tested artifact is what every node receives.

> In production, you would push this updated image to your container registry (Quay, Harbor, or any OCI-compliant registry). Every node in your fleet would then pull from the same registry, guaranteeing they all get the identical fix.

On each running Image Mode system, the upgrade is a single command:

```bash
sudo bootc upgrade
```

This pulls the new image from the registry, stages it alongside the current image, and reboots into the new version. After reboot, the system is running the patched image.

Verify the upgrade was applied:

```bash
sudo bootc status
```

The output now shows two images: the currently booted (new) image and the previous (rollback) image. The current image digest should match the image you just built.

Check the httpd version:

```bash
rpm -q httpd
```

The version should show the patched release.

#### Workflow Comparison

| Step | Traditional RHEL | Image Mode RHEL |
|---|---|---|
| Identify the fix | `dnf updateinfo` | Same — check the RHSA advisory |
| Apply the fix | `dnf update` on each node | Rebuild the image once |
| Validate | Test each node individually | Test the image once |
| Deploy to fleet | Repeat `dnf update` per node | `bootc upgrade` on each node (same image) |
| Consistency guarantee | None — each node patches independently | Image digest — every node runs the same bytes |
| Rollback | `dnf history undo` (may fail) | `bootc rollback` (atomic swap) |

---

### Step 6: Test Rollback

#### Traditional RHEL: dnf history undo

First, check the transaction history:

```bash
sudo dnf history
```

Find the transaction ID for the httpd update you just applied (it will be the most recent transaction). Then attempt a rollback:

```bash
sudo dnf history undo <transaction-id> -y
```

Check the result:

```bash
rpm -q httpd
```

If the rollback succeeded, the version reverts to the pre-patch release. But `dnf history undo` is not guaranteed to work. It attempts to downgrade individual packages, and if dependency relationships have changed — or if other packages were updated in the same transaction — the undo can fail or leave the system in a partially rolled-back state. This is an inherent limitation of the package-based model: each transaction mutates the system state, and reversing a mutation is harder than swapping between two complete states.

#### Image Mode: bootc rollback

On the Image Mode system:

```bash
sudo bootc status
```

Note that two images are listed: the current (patched) image and the previous (pre-patch) image. Both are stored on disk as complete filesystem trees.

Roll back:

```bash
sudo bootc rollback
sudo reboot
```

After reboot, verify:

```bash
sudo bootc status
```

The system is now running the previous image. The patched image is still stored as the rollback target — you can switch back and forth between the two.

```bash
rpm -q httpd
```

The version should show the pre-patch release, confirming the rollback was a clean swap to the previous filesystem tree — not an attempt to reverse individual package changes.

This is the core difference. On Image Mode, rollback is not a best-effort operation. It is a swap between two known, complete, tested OS images. The system cannot end up in a partially rolled-back state because there is no partial — you are running one image or the other.
