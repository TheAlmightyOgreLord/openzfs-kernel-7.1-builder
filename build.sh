#!/bin/bash
set -e

# --- Configuration ---
ZFS_VERSION="2.4.3"
WORK_DIR="$HOME/zfs-build-$$"
REPO_DIR="/var/lib/zfs-local-repo"
REPO_NAME="zfs-patched-local"

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (e.g., sudo $0)" 
   exit 1
fi

echo "🚀 Starting OpenZFS $ZFS_VERSION build for Kernel 7.1.x..."

# 1. Prepare Environment
echo "📦 Installing build dependencies..."
dnf install -y \
    git rpm-build rpmdevtools wget createrepo_c \
    kernel-devel kernel-headers \
    elfutils-libelf-devel zlib-devel libuuid-devel libblkid-devel \
    libtirpc-devel libselinux-devel libudev-devel \
    openssl-devel python3-devel python3-packaging libffi-devel \
    lz4-devel libzstd-devel \
    autoconf automake libtool \
    ksh ncompress \
    gcc make \
    dkms sysstat perl mokutil \
    lsb_release

mkdir -p "$WORK_DIR" "$REPO_DIR"
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# 2. Download Official Source
cd "$WORK_DIR"
echo "📥 Downloading official source..."
wget -q "https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_VERSION}/zfs-${ZFS_VERSION}.tar.gz"

# 3. Prepare RPM Build Environment
echo "🔧 Preparing source for RPM build..."
cp "zfs-${ZFS_VERSION}.tar.gz" ~/rpmbuild/SOURCES/


# ... (After copying tarball to SOURCES) ...

# CRITICAL FIX: Patch the source tree that rpmbuild will use
# This ensures the INSTALLED source in /usr/src/ has the correct META file
echo "   - Patching source tree for RPM build..."
cd ~/rpmbuild/SOURCES
tar xzf zfs-${ZFS_VERSION}.tar.gz
cd zfs-${ZFS_VERSION}

# Apply the Kernel 7.1 fix to the META file
sed -i 's/^Linux-Maximum: .*/Linux-Maximum: 7.1/' META

# Re-pack the tarball so rpmbuild uses the patched version
cd ..
tar czf zfs-${ZFS_VERSION}.tar.gz zfs-${ZFS_VERSION}
rm -rf zfs-${ZFS_VERSION}

echo "   - Source tarball patched and repacked."   


# C. Extract the NOW-PATCHED tarball to run configure and generate dkms.conf
# We extract from the patched SOURCES tarball, not the original WORK_DIR one
cd "$WORK_DIR"
tar xzf ~/rpmbuild/SOURCES/zfs-${ZFS_VERSION}.tar.gz
cd "zfs-${ZFS_VERSION}"

# D. Run configure to generate spec files
echo "   - Running configure..."
./configure --with-spec=redhat --enable-linux-experimental --without-libunwind --with-dkms

# E. Generate dkms.conf with correct arguments
echo "   - Generating module/dkms.conf..."
./scripts/dkms.mkconf -n zfs -v "${ZFS_VERSION}" -c META -f module/dkms.conf

if [ ! -s module/dkms.conf ] || ! grep -q "PACKAGE_NAME=" module/dkms.conf; then
    echo "❌ FAILED: module/dkms.conf is empty or invalid."
    exit 1
fi

# F. Copy the generated spec file
if [ -f rpm/redhat/zfs.spec ]; then
    cp rpm/redhat/zfs.spec ~/rpmbuild/SPECS/
elif [ -f rpm/generic/zfs.spec ]; then
    cp rpm/generic/zfs.spec ~/rpmbuild/SPECS/
else
    echo "❌ zfs.spec not found after configure"
    exit 1
fi

# G. Patch the SPEC file
echo "   - Patching zfs.spec..."
sed -i 's/%configure/%configure --enable-linux-experimental --without-libunwind/' ~/rpmbuild/SPECS/zfs.spec

# H. Patch the dkms.conf for multi-line PRE_BUILD
echo "   - Patching module/dkms.conf for Kernel 7.1..."
if ! grep -q "\-\-enable-linux-experimental" module/dkms.conf; then
    sed -i ':a;N;$!ba;s/\(PRE_BUILD="\([^"]*\)\)"/\1 --enable-linux-experimental"/g' module/dkms.conf
    if ! grep -q "\-\-enable-linux-experimental" module/dkms.conf; then
        echo "❌ Failed to patch dkms.conf."
        exit 1
    fi
fi

echo "✅ Section 3 Complete. Ready to build."

# 2. Run configure to generate spec files and Makefiles
# Use --enable-linux-experimental (NOT --enable-experimental)
echo "⚙️ Running configure..."
./configure --with-spec=redhat --enable-linux-experimental --without-libunwind --with-dkms

# 3. CRITICAL: Generate dkms.conf
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

# 4. Copy generated spec file
if [ -f rpm/redhat/zfs.spec ]; then
    cp rpm/redhat/zfs.spec ~/rpmbuild/SPECS/
elif [ -f rpm/generic/zfs.spec ]; then
    cp rpm/generic/zfs.spec ~/rpmbuild/SPECS/
else
    echo "❌ Failed to locate generated zfs.spec"
    exit 1
fi

# 5. Patch the SPEC file for experimental support
echo "🔧 Patching zfs.spec for experimental support..."
sed -i 's/%configure/%configure --enable-linux-experimental/' ~/rpmbuild/SPECS/zfs.spec

# 6. Patch the NOW-EXISTING dkms.conf
echo "   - Patching module/dkms.conf..."

# The PRE_BUILD block spans multiple lines. We need to inject the flag 
# before the closing quote of the PRE_BUILD variable.
# Strategy: Find the line ending the PRE_BUILD block (the standalone ") 
# and insert the flag on the line before it.

# 1. Check if the flag is already present
if grep -q "\-\-enable-linux-experimental" module/dkms.conf; then
    echo "   - Flag already present, skipping patch."
else
    # 2. Inject the flag before the closing quote of PRE_BUILD
    # We look for the line with the closing parenthesis and quote: )"
    # and insert the flag on the previous line.
    sed -i '/^  --with-linux-obj=/,/^\s*"/ {
        /^\s*"/ {
            s/^\s*"/  --enable-linux-experimental\n"/
        }
    }' module/dkms.conf

    # Alternative simpler approach if the above is too complex for your sed version:
    # Just append the flag to the specific line before the closing quote
    # Find the line with the last configure argument (usually --with-linux-obj) and append there
    if ! grep -q "\-\-enable-linux-experimental" module/dkms.conf; then
        # Fallback: Insert before the closing quote of PRE_BUILD
        # This regex finds the closing quote of the PRE_BUILD block and inserts the flag before it
        sed -i ':a;N;$!ba;s/\(PRE_BUILD="\([^"]*\)\)"/\1 --enable-linux-experimental"/g' module/dkms.conf
    fi

    # 3. Verify
    if grep -q "\-\-enable-linux-experimental" module/dkms.conf; then
        echo "   - dkms.conf patched successfully."
    else
        echo "❌ Failed to patch dkms.conf (flag not found)."
        echo "   --- Current PRE_BUILD Block ---"
        sed -n '/^PRE_BUILD=/,/^"/p' module/dkms.conf
        exit 1
    fi
fi

# 4. Build User-Space RPMs
echo "🏗️ Building user-space RPMs..."
rm -rf ~/rpmbuild/BUILD/zfs-*

rpmbuild -bb ~/rpmbuild/SPECS/zfs.spec \
    --define "with_experimental 1" \
    --define "with_utils 1" \
    --define "_topdir $HOME/rpmbuild" \
    --nodeps

if [ $? -ne 0 ]; then
    echo "❌ User-space RPM build failed."
    exit 1
fi

# 4b. Build the DKMS RPM specifically
echo "🏗️ Building zfs-dkms RPM..."

# Locate the generated dkms spec file
if [ -f rpm/redhat/zfs-dkms.spec ]; then
    DKMS_SPEC="rpm/redhat/zfs-dkms.spec"
elif [ -f rpm/generic/zfs-dkms.spec ]; then
    DKMS_SPEC="rpm/generic/zfs-dkms.spec"
else
    echo "❌ zfs-dkms.spec not found. DKMS support not enabled in configure."
    exit 1
fi

# Copy to SPECS dir (overwrite if exists)
cp "$DKMS_SPEC" ~/rpmbuild/SPECS/zfs-dkms.spec

# CRITICAL: Ensure the source tarball is in SOURCES for the dkms build
# The dkms spec expects to unpack the source to /usr/src/zfs-<version>
if [ ! -f ~/rpmbuild/SOURCES/zfs-${ZFS_VERSION}.tar.gz ]; then
    cp "$WORK_DIR/zfs-${ZFS_VERSION}.tar.gz" ~/rpmbuild/SOURCES/
fi

# Build the DKMS RPM
rpmbuild -bb ~/rpmbuild/SPECS/zfs-dkms.spec \
    --define "_topdir $HOME/rpmbuild" \
    --nodeps

if [ $? -ne 0 ]; then
    echo "❌ zfs-dkms RPM build failed."
    exit 1
fi

# 5. Verify and Locate DKMS RPM
echo "🔍 Locating generated RPMs..."

# CRITICAL: zfs-dkms is a noarch package.
DKMS_RPM=$(ls ~/rpmbuild/RPMS/noarch/zfs-dkms-${ZFS_VERSION}-*.noarch.rpm 2>/dev/null | head -n 1)

if [ -z "$DKMS_RPM" ]; then
    echo "❌ zfs-dkms RPM not found in noarch directory."
    echo "   --- Contents of ~/rpmbuild/RPMS/noarch/ ---"
    ls -lh ~/rpmbuild/RPMS/noarch/ 2>/dev/null || echo "   (Directory empty or missing)"
    exit 1
fi

echo "✅ Successfully built: $DKMS_RPM"
echo "   --- All Generated RPMs ---"
find ~/rpmbuild/RPMS -name "*.rpm" -type f

# 6. Create Local Repo
echo "📦 Setting up local DNF repository..."
mkdir -p "$REPO_DIR"
cp ~/rpmbuild/RPMS/x86_64/*.rpm "$REPO_DIR/"
cp ~/rpmbuild/RPMS/noarch/*.rpm "$REPO_DIR/"
createrepo_c "$REPO_DIR"

# 7. Configure DNF Priority
echo "⚙️ Configuring DNF priority..."
cat > /etc/yum.repos.d/${REPO_NAME}.repo <<EOF
[${REPO_NAME}]
name=Local Patched OpenZFS (Kernel 7.1 Support)
baseurl=file://${REPO_DIR}
enabled=1
gpgcheck=0
priority=10
EOF

# Cleanup
cd ..
rm -rf "$WORK_DIR"

echo "✅ SUCCESS!"
echo "   - Repository created at: $REPO_DIR"
echo "   - DNF config: /etc/yum.repos.d/${REPO_NAME}.repo"
echo ""
echo "Next steps:"
echo "   1. Remove old ZFS: dnf remove zfs zfs-dkms zfs-dracut"
echo "   2. Install from local repo: dnf install zfs zfs-dkms zfs-dracut --repo=${REPO_NAME}"
echo "   3. If Secure Boot is enabled, REBOOT to enroll MOK key (Password: secureboot)."
echo "   4. Load module: modprobe zfs"   

echo "✅ SUCCESS!"
echo "   - Repository created at: $REPO_DIR"
echo "   - DNF config: /etc/yum.repos.d/${REPO_NAME}.repo"
echo ""
echo "Next steps:"
echo "   1. Remove old ZFS: dnf remove zfs zfs-dkms zfs-dracut"
echo "   2. Install from local repo: dnf install zfs zfs-dkms zfs-dracut --repo=${REPO_NAME}"
