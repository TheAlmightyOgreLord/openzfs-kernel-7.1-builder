
> ⚡ **Bleeding Edge:** For **OpenZFS 2.4.4 + Kernel 7.2.0** support,
> use the [`zfs-2.4.4-k7.2`](https://github.com/TheAlmightyOgreLord/openzfs-kernel-7.1-builder/tree/zfs-2.4.4-k7.2) branch.
>
> ```bash
> git clone --branch zfs-2.4.4-k7.2 --single-branch --depth 1 \
>   https://github.com/TheAlmightyOgreLord/openzfs-kernel-7.1-builder.git
> ```
>
> This branch builds from [Tony Hutter's `zfs-2.4.4-hutter`](https://github.com/tonyhutter/zfs/tree/zfs-2.4.4-hutter)
> against Kernel 7.2.0 (via `@kernel-vanilla` COPR). Unofficial, community-maintained.

---

# OpenZFS Builder (Fedora 43/44 + Kernel 7.1.x)

A professional, self-contained build script for **OpenZFS 2.4.3** that creates an easy-to-manage offline DNF repo. 
Hardcoded and rigorously tested for **OpenZFS 2.4.3** on **Fedora 43/44** with **Linux Kernel 7.1.x**.

This script **backports official upstream commits** to natively support Kernel 7.1, eliminating the need for manual patches or experimental build flags.

## 🔧 Core Improvements (August 2026)

*   **Native Kernel 7.1 Support:** Applies **official upstream commit `a35e8d8`** (signed by OpenZFS maintainers Tony Hutter and Rob Norris) to update the `META` file.  This removes the "EXPERIMENTAL" kernel warning and the need for `--enable-linux-experimental`.
*   **Atomic Patching:** Uses `git apply` instead of `patch` for all changes. This ensures an **all-or-nothing** application: if a patch doesn't fit perfectly, the script aborts safely rather than creating a broken build.
*   **Critical Bug Fixes:** Backports **commit `223b8bc`** (Issue #18787: `mmap` underflow), **commit `027940e`** (Issue #18652: Dedup UBSAN), and **commit `3bd8cef`** (Issue #18883: Resume crash) to ensure stability on Kernel 7.1.   
*   **Native Async I/O Support:** Explicitly links libaio-devel to enable native asynchronous I/O.

    > Impact: Prevents fallback to inefficient POSIX emulation, ensuring maximum throughput and reduced latency for database and VM workloads.

*   **Enterprise SELinux Integration:** Explicitly links libattr-devel and allows the use of xattr=sa (System Attributes).

    > Impact: Enables granular, per-file SELinux labeling (required for strict security policies) and provides a ~3x performance improvement for metadata-heavy operations compared to directory-based xattrs. For root pools, enable maximum performance by setting ```zfs set xattr=sa <pool/dataset>``` and running ```restorecon -Rv /``` to migrate existing labels to the faster System Attribute format.
*   **Zero-Trust Model:** Configures its own temporary Git environment, requiring no prior user configuration or global Git settings.
*   **Native Support for Fedora 43/44:** Validated on clean installations of Fedora 43 (Kernel 7.1.7-100) and Fedora 44 (Kernel 7.1.7-200), including snapshot-based simulations to ensure reproducibility.   

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

- OS: Fedora 43 and Fedora 44 (Untested on other distros)

- Kernel: 7.1.x only

- Source: OpenZFS 2.4.3 (with official 2.4.4 backports)

## 🏭 Enterprise & CI/CD Integration

This script is designed for **automation-first** environments, enabling secure, scalable deployment of OpenZFS on bleeding-edge kernels.

*   **Build Integrity:** The script pre-installs all required build dependencies via `dnf` in a clean, isolated environment. The `rpmbuild --nodeps` flag is used safely to bypass redundant RPM database checks, ensuring builds do not fail due to transient metadata issues while maintaining full binary compatibility. 
*   **SBOM Ready:** The resulting RPMs contain complete dependency metadata (`Requires`/`Provides`) auto-generated from the compiled binaries. Standard enterprise tools (e.g., **Syft**, **Trivy**, **Anchore**) can instantly scan these RPMs to generate compliant **CycloneDX** or **SPDX** Software Bill of Materials (SBOM) artifacts. 
*   **Secure Boot & UKI:** Generates modules compatible with Secure Boot and Unified Kernel Image (UKI) workflows. Integrates seamlessly with CI/CD pipelines to sign modules using organization-held Machine Owner Keys (MOK). 
*   **Immutable Deployment:** Adopt a **"Build Once, Deploy Many"** strategy. Build the RPM in a CI pipeline (GitHub Actions, Jenkins, GitLab CI) and deploy the *exact same binary* across your entire cluster, ensuring bit-for-bit consistency and auditability.
*   **Provenance:** Documents exact upstream commits (`a35e8d8`, `223b8bc`) in the build process, satisfying **NIST SSDF** provenance requirements and enabling easy audit trails for regulated environments.

> **Example CI/CD Workflow:**
> 1. Trigger: Initiate build on new Kernel 7.1.x release (or when updating backport commits in the script).
> 2. Build: CI runs build.sh in an isolated container/VM, which automatically fetches source, applies patches, and builds RPMs.
> 3. Sign: CI signs RPMs and modules with organization Secure Boot keys.
> 4. Publish: CI pushes signed RPMs to a private DNF repository (e.g., GitHub Packages, Artifactory).
> 5. Deploy: On initial deployment, remove official packages and install from the local repo: dnf -y remove zfs zfs-dkms zfs-dracut libnvpair* libuutil* libzfs* libzpool* && dnf -y install zfs zfs-dkms zfs-dracut --repo=zfs-patched-local (Subsequent kernel updates will then handle ZFS modules automatically via the local repo.)

---

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

