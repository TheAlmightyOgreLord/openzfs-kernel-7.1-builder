#!/bin/bash
set -e

# --- Configuration ---
ZFS_VERSION="2.4.4"
WORK_DIR="/root/zfs-build-$$"
REPO_DIR="/var/lib/zfs-local-repo"
REPO_NAME="zfs-patched-local"

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (e.g., sudo $0)" 
   exit 1
fi

# CRITICAL: Guarantee cleanup on EXIT, ERROR, or INTERRUPT (Ctrl+C)
cleanup() {
    if [ -d "$WORK_DIR" ]; then
        echo "🧹 Cleaning up temporary build directory: $WORK_DIR"
	chmod -R +w "$WORK_DIR" 2>/dev/null || true
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM ERR

# --- Fedora Version Detection ---
FEDORA_VERSION=$(rpm -E %fedora)
echo "🔍 Detected Fedora version: $FEDORA_VERSION"

# Prepare Dependency List
DEPS=(
    git rpm-build rpmdevtools wget createrepo_c
    kernel-devel kernel-headers
    elfutils-libelf-devel zlib-devel libuuid-devel libblkid-devel
    libtirpc-devel libselinux-devel libudev-devel
    openssl-devel python3-devel python3-packaging libffi-devel python3-cffi
    lz4-devel libzstd-devel
    autoconf automake libtool
    ksh ncompress
    gcc make
    dkms sysstat perl mokutil
    libattr-devel libcurl-devel
    libaio-devel
)

# Fedora 44+ requires explicit python3-setuptools (removed from python3-devel deps)
if [[ $FEDORA_VERSION -ge 44 ]]; then
    echo "⚠️  Fedora 44+ detected: Adding explicit python3-setuptools dependency..."
    DEPS+=(python3-setuptools)
fi

# ✅ CI VALIDATION: Ensure critical dependencies are never omitted
# This prevents regressions where logic accidentally overwrites the DEPS array
CRITICAL_DEPS=("libaio-devel" "libattr-devel" "libcurl-devel" "python3-cffi")
echo "🛡️  Validating critical dependencies..."
for dep in "${CRITICAL_DEPS[@]}"; do
    if [[ ! " ${DEPS[@]} " =~ " ${dep} " ]]; then
        echo "❌ FATAL: Critical dependency '${dep}' is missing from DEPS array!"
        exit 1
    fi
done
echo "✅ All critical dependencies present."

# 1. Prepare Environment
echo "📦 Installing build dependencies..."
dnf install -y "${DEPS[@]}"

echo "🚀 Starting OpenZFS 2.4.4-hutter build for Kernel 7.2.0..."

mkdir -p "$WORK_DIR" "$REPO_DIR"
export RPMBUILD_OPT="--topdir $WORK_DIR"
mkdir -p "$WORK_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# 2. Clone Tony Hutter's 2.4.4 Branch (Direct Source)
cd "$WORK_DIR"
echo "📥 Cloning zfs-2.4.4-hutter branch (Kernel 7.2 ready)..."
git clone --depth 1 --branch zfs-2.4.4-hutter https://github.com/tonyhutter/zfs.git "$WORK_DIR/SOURCES/zfs-2.4.4"

# 3. Prepare RPM Build Environment from Git Source
echo "🔧 Preparing source for RPM build..."
cd "$WORK_DIR/SOURCES/zfs-2.4.4"

# CRITICAL: Generate a clean tarball for rpmbuild from the Git checkout
# This ensures the INSTALLED source in /usr/src/ has the correct META file and patches
echo "   - Creating build tarball from Git..."
# Remove .git directory to keep the tarball clean for rpmbuild
rm -rf .git


# Create the tarball expected by the spec file (adjust version string if needed)
cd "$WORK_DIR/SOURCES"

# Optional: Verify the META file shows the correct kernel compatibility
echo "   - Verifying META file..."
grep "Linux-Maximum" "$WORK_DIR/SOURCES/zfs-2.4.4/META" || echo "⚠️ Warning: META file check failed"

# 7. Generate build system (REQUIRED for git checkouts)
echo "⚙️ Generating configure script..."
cd "$WORK_DIR/SOURCES/zfs-2.4.4"
sh autogen.sh

# 7. Run configure to generate spec files and Makefiles
echo "⚙️ Running configure..."
./configure --with-spec=redhat --without-libunwind --with-config=srpm

make dist-gzip

mv zfs-2.4.4.tar.gz "$WORK_DIR/SOURCES/"

# 8. Copy the generated spec file
if [ -f rpm/redhat/zfs.spec ]; then
    cp rpm/redhat/zfs.spec "$WORK_DIR/SPECS/"
elif [ -f rpm/generic/zfs.spec ]; then
    cp rpm/generic/zfs.spec "$WORK_DIR/SPECS/"
else
    echo "❌ zfs.spec not found after configure"
    exit 1
fi

# 9. Patch the SPEC file
echo "   - Patching zfs.spec..."
SPEC_FILE="$WORK_DIR/SPECS/zfs.spec"

# 10. Inject changelog entry (Robust Method)
CHANGELOG_ENTRY="* Thu Aug 20 2026 Automated Build <builder@localhost> - ${ZFS_VERSION}-1
- Automated build for Kernel 7.2.0 (zfs-2.4.4-hutter branch)"

if grep -q "^%changelog" "$SPEC_FILE"; then
    # Case A: Section exists -> Insert after the %changelog line
    sed -i "/^%changelog/a $CHANGELOG_ENTRY" "$SPEC_FILE"
    echo "   - ✅ Injected changelog entry into existing section."
else
    # Case B: Section missing -> Append to end of file (Required for Fedora 44)
    echo "" >> "$SPEC_FILE"
    echo "%changelog" >> "$SPEC_FILE"
    echo "$CHANGELOG_ENTRY" >> "$SPEC_FILE"
    echo "   - ✅ Created new %changelog section (Required for Fedora 44)."
fi

# Verify the fix worked
if ! grep -q "Automated Build" "$SPEC_FILE"; then
    echo "   ❌ CRITICAL: Changelog injection failed. Build will likely fail."
    exit 1
fi

echo "✅ Section 3 Complete. Ready to build."


echo "🏗️ Building all RPMs (utils + dkms)..."
make -j1 rpm-utils rpm-dkms


# Extract the actual RPM paths from make output
echo "📦 Collecting RPMs..."
mkdir -p "$REPO_DIR"
# RPMs are in the source directory where make was run
RPM_SRC="$WORK_DIR/SOURCES/zfs-${ZFS_VERSION}"
if [ -d "$RPM_SRC" ]; then
    cp "$RPM_SRC"/*.rpm "$REPO_DIR/" 2>/dev/null
fi

# Fallback: search the entire work dir
find "$WORK_DIR" -name "*.rpm" -newer "$WORK_DIR/SOURCES/zfs-${ZFS_VERSION}.tar.gz" \
    -exec cp {} "$REPO_DIR/" \; 2>/dev/null

# Verify
RPM_COUNT=$(ls -1 "$REPO_DIR"/*.rpm 2>/dev/null | wc -l)
if [ "$RPM_COUNT" -eq 0 ]; then
    echo "❌ No RPMs found. Searching /tmp..."
    find /tmp -name "zfs-*.rpm" -newer /tmp -mmin -10 -exec cp {} "$REPO_DIR/" \; 2>/dev/null
    RPM_COUNT=$(ls -1 "$REPO_DIR"/*.rpm 2>/dev/null | wc -l)
fi

echo "   - $RPM_COUNT RPMs in $REPO_DIR"


createrepo_c "$REPO_DIR"   

# 15. Configure DNF Priority
echo "⚙️ Configuring DNF priority..."
cat > /etc/yum.repos.d/${REPO_NAME}.repo <<EOF
[${REPO_NAME}]
name=Local Patched OpenZFS (Kernel 7.1 Support)
baseurl=file://${REPO_DIR}
enabled=1
gpgcheck=0
priority=10
EOF

echo "🧹 Cleaning up build environment..."
cd /
# Force permissions before deletion to handle read-only .git objects
chmod -R +w "$WORK_DIR" 2>/dev/null || true
rm -rf "$WORK_DIR"

echo "✅ SUCCESS!"
echo "   - Repository created at: $REPO_DIR"
echo "   - DNF config: /etc/yum.repos.d/${REPO_NAME}.repo"
echo ""
echo "Next steps:"
echo "   1. Remove old ZFS and dependencies: dnf remove zfs zfs-dkms zfs-dracut libnvpair* libuutil* libzfs* libzpool* --setopt protected_packages="
echo "   2. Install from local repo (pulls isolated dependencies): dnf install zfs zfs-dkms zfs-dracut --repo=${REPO_NAME}"
echo "Note: if the 1st step removes \`dkms\` as unused, you will need to run \`sudo dnf -y install dkms\` before re-install in step 2."
