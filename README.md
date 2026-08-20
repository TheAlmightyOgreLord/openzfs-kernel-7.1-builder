# OpenZFS Builder (Fedora 43/44 + Kernel 7.2.x)

## Source
This build script uses the [`zfs-2.4.4-hutter`](https://github.com/tonyhutter/zfs/tree/zfs-2.4.4-hutter)
branch from [Tony Hutter's fork](https://github.com/tonyhutter/zfs) as its source.
This is an **unofficial, community-maintained** build script. It is not endorsed
by Tony Hutter, the OpenZFS project, or Klara Systems.

This script runs as sudo, builds openzfs v2.4.4-hutter against kernel 7.2.x within its own sandbox, creates a prioritized local dnf repo, and cleans up afterwards.

## 🔧 Core Improvements (August 2026)

*   **Native Kernel 7.2 Support:** Uses Tony Hutter's 2.4.4 upstream branch for kernel 7.2.x support
*   **Native Async I/O Support:** Explicitly links libaio-devel to enable native asynchronous I/O.

    > Impact: Prevents fallback to inefficient POSIX emulation, ensuring maximum throughput and reduced latency for database and VM workloads.

*   **Enterprise SELinux Integration:** Explicitly links libattr-devel and allows the use of xattr=sa (System Attributes).

    > Impact: Enables granular, per-file SELinux labeling (required for strict security policies) and provides a ~3x performance improvement for metadata-heavy operations compared to directory-based xattrs. For root pools, enable maximum performance by setting ```zfs set xattr=sa <pool/dataset>``` and running ```restorecon -Rv /``` to migrate existing labels to the faster System Attribute format.
*   **Zero-Trust Model:** Minimal, builds from source, you trust your own .rpm's locally built on your machine.
*   **Native Support for Fedora 43/44:** Validated on clean installations of Fedora 43 with Kernel 7.2.0-259.vanilla.fc43.x86_64. (**Fedora 44 is not tested yet, use at your own risk**), including snapshot-based simulations to ensure reproducibility.

## 🚀 Quick Start

## Prerequisites: Install Kernel 7.2.0 on Fedora 43

Fedora 43 stable is currently on **7.1.8-100**, which lacks critical
Bluetooth CVE fixes (CVE-2026-68189, CVE-2026-1001). Kernel **7.2.0**
(released Aug 16, 2026) patches all of them.

### 1. Enable the Kernel Vanilla COPR 
> Be aware you're trusting a copr repo, for true zero-trust build from source or wait for 7.2.x to drop

```bash
sudo dnf -y copr enable @kernel-vanilla/stable

sudo dnf -y install kernel-7.2.0 kernel-devel-7.2.0 kernel-headers-7.2.0
```
> Note: May require signing kernel using pesign to get it to boot

### 2. Clone This Branch
```bash
git clone --branch zfs-2.4.4-k7.2 --single-branch --depth 1 https://github.com/TheAlmightyOgreLord/openzfs-kernel-7.1-builder.git
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

- OS: Fedora 43 and Fedora 44 (Untested on Fedora 44 and other distros)

- Kernel: 7.1.x - 7.2.x

- Source: OpenZFS 2.4.4 (Tony Hutter's upstream branch)

## 🏭 Enterprise & CI/CD Integration

This script is designed for **automation-first** environments, enabling secure, scalable deployment of OpenZFS on bleeding-edge kernels.

*   **Build Integrity:** The script pre-installs all required build dependencies via `dnf` in a clean, isolated environment. The `rpmbuild --nodeps` flag is used safely to bypass redundant RPM database checks, ensuring builds do not fail due to transient metadata issues while maintaining full binary compatibility. 
*   **SBOM Ready:** The resulting RPMs contain complete dependency metadata (`Requires`/`Provides`) auto-generated from the compiled binaries. Standard enterprise tools (e.g., **Syft**, **Trivy**, **Anchore**) can instantly scan these RPMs to generate compliant **CycloneDX** or **SPDX** Software Bill of Materials (SBOM) artifacts. 
*   **Secure Boot & UKI:** Generates modules compatible with Secure Boot and Unified Kernel Image (UKI) workflows. Integrates seamlessly with CI/CD pipelines to sign modules using organization-held Machine Owner Keys (MOK). 
*   **Immutable Deployment:** Adopt a **"Build Once, Deploy Many"** strategy. Build the RPM in a CI pipeline (GitHub Actions, Jenkins, GitLab CI) and deploy the *exact same binary* across your entire cluster, ensuring bit-for-bit consistency and auditability.

> **Example CI/CD Workflow:**
> 1. Trigger: Initiate build on new Kernel 7.2.x release.
> 2. Build: CI runs build.sh in an isolated container/VM, which automatically fetches source, applies patches, and builds RPMs.
> 3. Sign: CI signs RPMs and modules with organization Secure Boot keys.
> 4. Publish: CI pushes signed RPMs to a private DNF repository (e.g., GitHub Packages, Artifactory).
> 5. Deploy: On initial deployment, remove official packages and install from the local repo: dnf -y remove zfs zfs-dkms zfs-dracut libnvpair* libuutil* libzfs* libzpool* && dnf -y install zfs zfs-dkms zfs-dracut --repo=zfs-patched-local (Subsequent kernel updates will then handle ZFS modules automatically via the local repo.)

---

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

