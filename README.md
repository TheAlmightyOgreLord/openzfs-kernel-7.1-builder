# OpenZFS Builder (Fedora 43 + Kernel 7.1.x)

A clean, self-contained, build script for **OpenZFS 2.4.3** that creates an easy-to-manage offline DNF repo.
Hardcoded and rigorously tested for **Fedora 43** with **Linux Kernel 7.1.x**.

# 🔧 Testing Methodology:
Validated against fresh Fedora 43 VM snapshots with reproducible success.

## 🚀 Quick Start

```bash
git clone https://github.com/TheAlmightyOgreLord/openzfs-kernel-7.1-builder.git
cd openzfs-kernel-7.1-builder
sudo ./build.sh

```

## 🛡️ Features

Creates an offline, self-contained OpenZFS repo for rolling kernel updates on Fedora 43

Stable Source: Targets the official OpenZFS 2.4.3 release tag.

Clean: Removes all build artifacts upon completion.

## ⚠️ Constraints

OS: Fedora 43 (Untested on other distros)

Kernel: 7.1.x only

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.
