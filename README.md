# OpenZFS Builder (DNF Distributions + Kernel 7.1.x - 7.2.x)

This build script clones the [`zfs-2.4.4`](https://github.com/openzfs/zfs/releases/tag/zfs-2.4.4)
tag from the [official OpenZFS repository](https://github.com/openzfs/zfs) by default.
It is an **unofficial, community-maintained** build script. It is not endorsed
by the OpenZFS project or Klara Systems.

The script runs as sudo (self-checks to avoid confusion), builds OpenZFS from source within its own `rpmbuild`
sandbox, creates a prioritized local dnf repo, and cleans up afterwards.

## ⚙️ Dynamic Versioning

By default, the script builds **OpenZFS 2.4.4**. To build any other version
or branch, edit the top of `build.sh`:

```bash
ZFS_VERSION="2.4.4"
ZFS_BRANCH="zfs-2.4.4"   # or: "zfs-2.4-release", "master", etc.   

```

## 🔧 Core Improvements (August 2026)

*   **Native Kernel 7.1 & 7.2 Support:** Uses OpenZFS 2.4.4 upstream release branch for kernel 7.1.x - 7.2.x support
*   **Native Async I/O Support:** Explicitly links libaio-devel to enable native asynchronous I/O.

    > Impact: Prevents fallback to inefficient POSIX emulation, ensuring maximum throughput and reduced latency for database and VM workloads.

*   **Enterprise SELinux Integration:** Explicitly links libattr-devel and allows the use of xattr=sa (System Attributes).

    > Impact: Enables granular, per-file SELinux labeling (required for strict security policies) and provides a ~3x performance improvement for metadata-heavy operations compared to directory-based xattrs. For root pools, enable maximum performance by setting ```zfs set xattr=sa <pool/dataset>``` and running ```restorecon -Rv /``` to migrate existing labels to the faster System Attribute format.
*   **Zero-Trust Model:** Minimal, builds from source, you trust your own .rpm's built locally on your machine.
*   **Native Support for Fedora 43/44:** Validated on clean installations of Fedora 43 (Kernel 7.1.9-100), and Fedora 44 (Kernel 7.1.9-200 & 7.2.0-259.vanilla), using snapshot-based simulations to ensure reproducibility.

## 🚀 Quick Start

```bash
git clone https://github.com/TheAlmightyOgreLord/openzfs-kernel-7.1-builder.git
cd openzfs-kernel-7.1-builder
sudo ./build.sh
```
## 🔄 Updating Your Build
To update to a newer version of this patched build:
1.  **Re-run the script**: Simply execute `./build.sh` again.
    *   The script will automatically overwrite the old RPMs in the local repository.
    *   It will refresh the DNF metadata to recognize the new version.
2.  **Reinstall/Upgrade**: Run the standard install command:
    ```bash
    sudo dnf -y remove zfs zfs-dkms zfs-dracut libnvpair* libuutil* libzfs* libzpool* --setopt protected_packages=
    sudo dnf -y install zfs zfs-dkms zfs-dracut --repo=zfs-patched-local
    ```
    *   DNF will detect the newer RPMs in your local repo and upgrade seamlessly.
    *   if the 1st step removes `dkms` as unused, you will need to run `sudo dnf -y install dkms` before re-install in step 2.
    *   **No manual cleanup of `/etc/yum.repos.d/` is required.**   

## 🛡️ Features
- Isolated Build: Downloads and builds OpenZFS from official upstream sources in a temporary directory.

- Offline DNF Repo: Creates a prioritized local repository (/etc/yum.repos.d/) for seamless kernel updates without conflicts that can coexist alongside the official repo.

- Clean Teardown: Removes all build artifacts and temporary Git data upon completion.

- Secure Boot Ready: Generates modules compatible with Secure Boot and UKI workflows (requires standard Fedora key enrollment).


## ⚠️ Constraints

- **OS:** Fedora 43/44 (Fully validated). Also supports **RHEL 9**, **CentOS Stream 9**, **AlmaLinux 9**, **Rocky Linux 9**, and **Oracle Linux 9** via automatic distro detection.
  - *Logic verified for all DNF-based RPM distributions.*

- Kernel: 7.1.x - 7.2.x

- Source: OpenZFS 2.4.4 (Stable upstream release branch)

## 🏭 Enterprise & CI/CD Integration

This script is designed for **automation-first** environments, enabling secure, scalable deployment of OpenZFS on bleeding-edge kernels.

*   **Build Integrity:** The script pre-installs all required build dependencies via `dnf` in a clean, isolated environment. The `rpmbuild --nodeps` flag is used safely to bypass redundant RPM database checks, ensuring builds do not fail due to transient metadata issues while maintaining full binary compatibility. 
*   **SBOM Ready:** The resulting RPMs contain complete dependency metadata (`Requires`/`Provides`) auto-generated from the compiled binaries. Standard enterprise tools (e.g., **Syft**, **Trivy**, **Anchore**) can instantly scan these RPMs to generate compliant **CycloneDX** or **SPDX** Software Bill of Materials (SBOM) artifacts. 
*   **Secure Boot & UKI:** Generates modules compatible with Secure Boot and Unified Kernel Image (UKI) workflows. Integrates seamlessly with CI/CD pipelines to sign modules using organization-held Machine Owner Keys (MOK). 
*   **Immutable Deployment:** Adopt a **"Build Once, Deploy Many"** strategy. Build the RPM in a CI pipeline (GitHub Actions, Jenkins, GitLab CI) and deploy the *exact same binary* across your entire cluster, ensuring bit-for-bit consistency and auditability.

> **Example CI/CD Workflow:**
> 1. Trigger: Initiate build on new Kernel 7.1.x/7.2.x release.
> 2. Build: CI runs build.sh in an isolated container/VM, which automatically fetches source, applies patches, and builds RPMs.
> 3. Sign: CI signs RPMs and modules with organization Secure Boot keys.
> 4. Publish: CI pushes signed RPMs to a private DNF repository (e.g., GitHub Packages, Artifactory).
> 5. Deploy: On initial deployment, remove official packages and install from the local repo: dnf -y remove zfs zfs-dkms zfs-dracut libnvpair* libuutil* libzfs* libzpool* && dnf -y install zfs zfs-dkms zfs-dracut --repo=zfs-patched-local (Subsequent kernel updates will then handle ZFS modules automatically via the local repo.)

---

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

