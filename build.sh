#!/bin/bash
set -e

# --- Configuration ---
ZFS_VERSION="2.4.3"
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

echo "🚀 Starting OpenZFS $ZFS_VERSION build for Kernel 7.1.x..."

mkdir -p "$WORK_DIR" "$REPO_DIR"
export RPMBUILD_OPT="--topdir $WORK_DIR"
mkdir -p "$WORK_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# 2. Download Official Source
cd "$WORK_DIR"
echo "📥 Downloading official source..."
wget -q "https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_VERSION}/zfs-${ZFS_VERSION}.tar.gz"

# 3. Prepare RPM Build Environment
echo "🔧 Preparing source for RPM build..."
cp "zfs-${ZFS_VERSION}.tar.gz" "$WORK_DIR/SOURCES/"

# ... (After copying tarball to SOURCES) ...

# CRITICAL FIX: Patch the source tree that rpmbuild will use
# This ensures the INSTALLED source in /usr/src/ has the correct META file
echo "   - Patching source tree for RPM build..."
cd "$WORK_DIR/SOURCES"
tar xzf zfs-${ZFS_VERSION}.tar.gz
cd zfs-${ZFS_VERSION}

# Initialize a temporary git repo to allow 'git apply' (cleaner than 'patch')
git init -q
# Set local dummy identity to avoid "Author identity unknown" errors on fresh systems
git config user.email "builder@localhost"
git config user.name "OpenZFS Builder"
git add -A
git commit -q -m "Initial upstream source"

# 4. Apply OFFICIAL Kernel 7.1 META fix (Commit a35e8d8)
# Replaces manual sed with the exact upstream change signed by maintainers
echo "   - Backporting official META fix for Linux 7.1 (Commit a35e8d8)..."
if ! curl -sSL "https://github.com/openzfs/zfs/commit/a35e8d8.patch" | git apply -; then
    echo "   - ❌ ERROR: Failed to apply official META patch."
    exit 1
fi
echo "   - ✅ Official META patch applied."

# 5. Apply the REAL fix for Issue #18787 (mmap read underflow)
# Backports commit 223b8bc using git apply for atomic safety
echo "   - Backporting upstream fix for Issue #18787 (zfs_fillpage underflow)..."
if ! curl -sSL "https://github.com/openzfs/zfs/commit/223b8bc.patch" | git apply -; then
    echo "   - ❌ ERROR: Failed to apply Issue #18787 fix."
    exit 1
fi
echo "   - ✅ Issue #18787 fix applied."

# Apply the fix for Issue #18652 (UBSAN negative shift in zbookmark_compare)
echo "   - Backporting upstream fix for Issue #18652 (UBSAN negative shift in zbookmark_compare)..."
if ! curl -sSL "https://github.com/openzfs/zfs/commit/027940e.patch" | git apply -; then
    echo "   - ❌ ERROR: Failed to apply Issue #18652 fix."
    exit 1
fi
echo "   - ✅ Issue #18652 fix applied."

# Apply a critical fix for issue #18883 (zfs send -t [resume] reliability)
echo "   - Backporting upstream fix for Issue #18883 (zfs send -t [resume] reliability)..."
if ! curl -sSL "https://github.com/openzfs/zfs/commit/3bd8cef.patch" | git apply -; then
    echo "   - ❌ ERROR: Failed to apply Issue #18883 fix."
    exit 1
fi
echo "   - ✅ Issue #18883 fix applied."

# Cleanup temporary git data (optional, keeps source tree clean for rpmbuild)
rm -rf .git
sync
sleep 1

echo "   - ✅ Source tree successfully patched with upstream commits."   

# Re-pack the tarball so rpmbuild uses the patched version
cd ..
tar czf zfs-${ZFS_VERSION}.tar.gz zfs-${ZFS_VERSION}
rm -rf zfs-${ZFS_VERSION}

echo "   - Source tarball patched and repacked."   

# 6. Extract the NOW-PATCHED tarball to run configure and generate dkms.conf
# We extract from the patched SOURCES tarball, not the original WORK_DIR one
cd "$WORK_DIR"
tar xzf "$WORK_DIR/SOURCES/zfs-${ZFS_VERSION}.tar.gz"
cd "zfs-${ZFS_VERSION}"

# 7. Run configure to generate spec files and Makefiles
echo "⚙️ Running configure..."
./configure --with-spec=redhat --without-libunwind

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
CHANGELOG_ENTRY="* Mon Aug 10 2026 Automated Build <builder@localhost> - ${ZFS_VERSION}-1
- Automated build for Kernel 7.1.x (Backports: a35e8d8, 223b8bc, 027940e, 3bd8cef)"

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

# 11. CRITICAL: Generate dkms.conf
echo "   - Generating module/dkms.conf..."

# Ensure we are in the source root for relative paths to work correctly
cd "$WORK_DIR/zfs-${ZFS_VERSION}"

# Run mkconf with explicit arguments
./scripts/dkms.mkconf \
    -n zfs \
    -v "${ZFS_VERSION}" \
    -c META \
    -f module/dkms.conf

# Verify success
if [ ! -s module/dkms.conf ] || ! grep -q "PACKAGE_NAME=" module/dkms.conf; then
    echo "❌ FAILED: module/dkms.conf is empty or invalid."
    cat module/dkms.conf
    exit 1
fi

echo "   - dkms.conf generated successfully."

RPMBUILD_CMD=(rpmbuild --define "_topdir $WORK_DIR")

# 12. Build User-Space RPMs
echo "🏗️ Building user-space RPMs..."
"${RPMBUILD_CMD[@]}" -bb "$WORK_DIR/SPECS/zfs.spec" \
    --define "with_utils 1" \
    --nodeps

if [ $? -ne 0 ]; then
    echo "❌ User-space RPM build failed."
    exit 1
fi

# 13. Build the DKMS RPM specifically
echo "🏗️ Building zfs-dkms RPM..."

# A. Locate the generated dkms spec file
if [ -f rpm/redhat/zfs-dkms.spec ]; then
    DKMS_SPEC_SRC="rpm/redhat/zfs-dkms.spec"
elif [ -f rpm/generic/zfs-dkms.spec ]; then
    DKMS_SPEC_SRC="rpm/generic/zfs-dkms.spec"
else
    echo "❌ zfs-dkms.spec not found. DKMS support not enabled in configure."
    exit 1
fi

# B. Copy to WORK_DIR/SPECS
DKMS_SPEC_DEST="$WORK_DIR/SPECS/zfs-dkms.spec"
cp "$DKMS_SPEC_SRC" "$DKMS_SPEC_DEST"

# C. CRITICAL: Inject %changelog if missing (Required for Fedora 44)
# OpenZFS upstream specs often omit this, causing build failures on modern Fedora
if ! grep -q "^%changelog" "$DKMS_SPEC_DEST"; then
    echo "   - Injecting missing %changelog section into DKMS spec..."
    {
        echo ""
        echo "%changelog"
        echo "* Mon Aug 03 2026 Automated Build <builder@localhost> - ${ZFS_VERSION}-1"
        echo "- Automated DKMS build with upstream backports"
    } >> "$DKMS_SPEC_DEST"
fi

# D. Build using the ARRAY variable (Ensures _topdir is correctly parsed)
# This forces rpmbuild to use $WORK_DIR, preventing fallback to /root/rpmbuild
if ! "${RPMBUILD_CMD[@]}" -bb "$DKMS_SPEC_DEST" --nodeps; then
    echo "❌ zfs-dkms RPM build failed."
    exit 1
fi

echo "✅ zfs-dkms RPM built successfully in $WORK_DIR/RPMS/noarch/"

# 14. Create Local Repo
echo "📦 Setting up local DNF repository..."
mkdir -p "$REPO_DIR"
cp "$WORK_DIR/RPMS/x86_64/"*.rpm "$REPO_DIR/"
cp "$WORK_DIR/RPMS/noarch/"*.rpm "$REPO_DIR/"
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
