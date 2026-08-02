# OpenZFS Builder (Fedora 43 + Kernel 7.1.x)

A professional, self-contained build script for **OpenZFS 2.4.3** that creates an easy-to-manage offline DNF repo. 
Hardcoded and rigorously tested for **Fedora 43** with **Linux Kernel 7.1.x**.

This script **backports official upstream commits** to natively support Kernel 7.1, eliminating the need for manual patches or experimental build flags.

## 🔧 Core Improvements (August 2026)

*   **Native Kernel 7.1 Support:** Applies **official upstream commit `a35e8d8`** (signed by OpenZFS maintainers Tony Hutter and Rob Norris) to update the `META` file.  This removes the "EXPERIMENTAL" kernel warning and the need for `--enable-linux-experimental`.
*   **Atomic Patching:** Uses `git apply` instead of `patch` for all changes. This ensures an **all-or-nothing** application: if a patch doesn't fit perfectly, the script aborts safely rather than creating a broken build.
*   **Critical Bug Fix:** Backports **commit `223b8bc`** to resolve **Issue #18787** (mmap read underflow/memory corruption) present in vanilla 2.4.3 on Kernel 7.1. 
*   **Zero-Trust Model:** Configures its own temporary Git environment, requiring no prior user configuration or global Git settings.

## 🚀 Quick Start

```bash
git clone https://github.com/TheAlmightyOgreLord/openzfs-kernel-7.1-builder.git
cd openzfs-kernel-7.1-builder
sudo ./build.sh
```

## 🛡️ Features
- Isolated Build: Downloads and builds OpenZFS from official upstream sources in a temporary directory.

- Offline DNF Repo: Creates a prioritized local repository (/etc/yum.repos.d/) for seamless kernel updates without conflicts that can coexist alongside the official repo.

- Clean Teardown: Removes all build artifacts and temporary Git data upon completion.

- Secure Boot Ready: Generates modules compatible with Secure Boot and UKI workflows (requires standard Fedora key enrollment).

## ⚠️ Constraints

- OS: Fedora 43 (Untested on other distros)

- Kernel: 7.1.x only

- Source: OpenZFS 2.4.3 (with official 2.4.4 backports) 

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.
