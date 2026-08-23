#!/bin/bash
set -euo pipefail

# --- Configuration ---
ZFS_VERSION="2.4.4"
ZFS_BRANCH="${ZFS_BRANCH:-zfs-${ZFS_VERSION}}" # Defaults to tag, but can be overridden
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

# Detect Distro ID
source /etc/os-release
DISTRO_ID=${ID,,} # Convert to lowercase

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

if [[ "$DISTRO_ID" == "fedora" ]]; then
    FEDORA_VERSION=$(rpm -E %fedora)
    echo "🔍 Detected Fedora version: $FEDORA_VERSION"

    # Fedora 44+ requires explicit python3-setuptools
    if [[ $FEDORA_VERSION -ge 44 ]]; then
        echo "⚠️  Fedora 44+ detected: Adding explicit python3-setuptools dependency..."
        DEPS+=(python3-setuptools)
    fi
    # Fedora <=43: Relies on transitive dep from python3-devel (Correct)
else
    # RHEL, CentOS, Alma, Rocky, etc. ALWAYS need explicit setuptools
    # They never had it as a transitive dependency in recent versions
    echo "ℹ️  Non-Fedora RPM distro detected ($DISTRO_ID): Adding explicit python3-setuptools dependency..."
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

echo "🚀 Starting OpenZFS ${ZFS_VERSION} build for Kernel 7.2.x..."

mkdir -p "$WORK_DIR" "$REPO_DIR"
export RPMBUILD_OPT="--topdir $WORK_DIR"
mkdir -p "$WORK_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cd "$WORK_DIR"

# 2. Clone using the dynamic branch variable
echo "📥 Cloning OpenZFS ${ZFS_BRANCH}..."
git clone --depth 1 --branch "${ZFS_BRANCH}" -c advice.detachedHead=false \
  https://github.com/openzfs/zfs.git "$WORK_DIR/SOURCES/zfs-${ZFS_VERSION}" 2>&1 | grep -v "is not a commit"

# 3. Prepare RPM Build Environment from Git Source
echo "🔧 Preparing source for RPM build..."
cd "$WORK_DIR/SOURCES/zfs-${ZFS_VERSION}"

# CRITICAL: Generate a clean tarball for rpmbuild from the Git checkout
# This ensures the INSTALLED source in /usr/src/ has the correct META file and patches
echo "   - Creating build tarball from Git..."
# Remove .git directory to keep the tarball clean for rpmbuild
rm -rf .git


# Create the tarball expected by the spec file (adjust version string if needed)
cd "$WORK_DIR/SOURCES"

# Optional: Verify the META file shows the correct kernel compatibility
echo "   - Verifying META file..."
grep "Linux-Maximum" "$WORK_DIR/SOURCES/zfs-${ZFS_VERSION}/META" || echo "⚠️ Warning: META file check failed"

# 4. Generate build system (REQUIRED for git checkouts)
echo "⚙️ Generating configure script..."
cd "$WORK_DIR/SOURCES/zfs-${ZFS_VERSION}"
sh autogen.sh

# 5. Run configure to generate spec files and Makefiles
echo "⚙️ Running configure..."
./configure --with-spec=redhat --without-libunwind --with-config=srpm

make dist-gzip

mv zfs-2.4.4.tar.gz "$WORK_DIR/SOURCES/"

# 6. Copy the generated spec file
if [ -f rpm/redhat/zfs.spec ]; then
    cp rpm/redhat/zfs.spec "$WORK_DIR/SPECS/"
elif [ -f rpm/generic/zfs.spec ]; then
    cp rpm/generic/zfs.spec "$WORK_DIR/SPECS/"
else
    echo "❌ zfs.spec not found after configure"
    exit 1
fi

# 7. Patch the SPEC file
echo "   - Patching zfs.spec..."
SPEC_FILE="$WORK_DIR/SPECS/zfs.spec"

# 8. Inject changelog entry (Robust Method)
CHANGELOG_ENTRY="* Thu Aug 22 2026 Automated Build <builder@localhost> - ${ZFS_VERSION}-1
- Automated build for Kernel 7.2.x (zfs-${ZFS_VERSION}-stable branch)"

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


# 9. Extract the actual RPM paths from make output
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

# 10. Verify
RPM_COUNT=$(ls -1 "$REPO_DIR"/*.rpm 2>/dev/null | wc -l)
if [ "$RPM_COUNT" -eq 0 ]; then
    echo "❌ No RPMs found. Searching /tmp..."
    find /tmp -name "zfs-*.rpm" -newer /tmp -mmin -10 -exec cp {} "$REPO_DIR/" \; 2>/dev/null
    RPM_COUNT=$(ls -1 "$REPO_DIR"/*.rpm 2>/dev/null | wc -l)
fi

echo "   - $RPM_COUNT RPMs in $REPO_DIR"


createrepo_c "$REPO_DIR"   

# 11. Configure DNF Priority
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
