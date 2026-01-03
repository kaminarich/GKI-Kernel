#!/bin/bash

# =========================================================
# GKI KERNEL BUILDER AUTOMATION (LOCAL LINUX)
# Interactive Script
# =========================================================

# Terminal Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}=================================================${NC}"
echo -e "${YELLOW}      GKI ANDROID 12-5.10 BUILDER (LOCAL)      ${NC}"
echo -e "${BLUE}=================================================${NC}"

# =========================================================
# 1. USER INPUT (INTERACTIVE)
# =========================================================

# A. Input Kernel Name
read -p "Enter Kernel Name (Default: KSUN-Milenium): " INPUT_NAME
KERNEL_NAME="${INPUT_NAME:-KSUN-Milenium}"

# B. Select Clang Version
echo -e "\nSelect Clang Version:"
echo "1) Clang 19 (r536225)"
echo "2) Clang 20 (r547379) - Default"
read -p "Choice (1/2): " CLANG_OPT

if [ "$CLANG_OPT" == "1" ]; then
    CLANG_VER="clang-r536225"
    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main-kernel-2025/clang-r536225.tar.gz"
    echo -e "-> Using: ${YELLOW}Clang 19${NC}"
else
    CLANG_VER="clang-r547379"
    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/62cdcefa89e31af2d72c366e8b5ef8db84caea62/clang-r547379.tar.gz"
    echo -e "-> Using: ${YELLOW}Clang 20${NC}"
fi

# C. Work Directory
read -p "Enter Work Directory (Default: gki_build): " INPUT_DIR
BASE_DIR="${INPUT_DIR:-gki_build}"
WORK_DIR="$(pwd)/$BASE_DIR"
echo -e "-> Work Dir: ${GREEN}$WORK_DIR${NC}"

# D. Dependency Installation Check
echo -e "\nInstall/Update dependencies (apt)? (y/n)"
read -p "Choice: " DEP_OPT

echo -e "${BLUE}=================================================${NC}"
echo -e "Configuration Complete. Starting in 3 seconds..."
sleep 3

set -e # Abort on error

# =========================================================
# 2. INSTALL DEPENDENCIES
# =========================================================
if [[ "$DEP_OPT" == "y" || "$DEP_OPT" == "Y" ]]; then
    echo -e "\n${GREEN}=== [1/9] Installing Dependencies ===${NC}"
    sudo apt update
    sudo apt install -y git curl repo build-essential bc bison flex libssl-dev \
      libelf-dev python3 python3-pip unzip zip rsync libncurses-dev lld ccache
    
    # Configure Git identity if missing
    if [ -z "$(git config --global user.name)" ]; then
        git config --global user.name "Builder"
        git config --global user.email "builder@localhost"
    fi
else
    echo -e "\n${YELLOW}=== [1/9] Skipping Dependencies ===${NC}"
fi

# =========================================================
# 3. INITIALIZE REPO
# =========================================================
echo -e "\n${GREEN}=== [2/9] Initialize Google Repo ===${NC}"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -d ".repo" ]; then
    echo "Initializing repo..."
    repo init -u https://android.googlesource.com/kernel/manifest -b common-android12-5.10 --depth=1
fi

echo "Syncing repo (this may take time)..."
repo sync -c --no-tags --no-clone-bundle --optimized-fetch -j$(nproc --all)

# =========================================================
# 4. SWAP SOURCE TO MILLENNIUM
# =========================================================
echo -e "\n${GREEN}=== [3/9] Swap Source to MillenniumOSS ===${NC}"
cd "$WORK_DIR"
if [ -d "common" ]; then
    # Ensure a clean slate by removing existing common dir
    echo "Removing old common directory..."
    rm -rf common
fi

echo "Cloning MillenniumOSS..."
git clone https://github.com/MillenniumOSS/android_kernel_common_android12-5.10.git common

# =========================================================
# 5. SETUP CLANG
# =========================================================
echo -e "\n${GREEN}=== [4/9] Setup Clang ($CLANG_VER) ===${NC}"
cd "$WORK_DIR"
mkdir -p prebuilts-master/clang/host/linux-x86/$CLANG_VER
cd prebuilts-master/clang/host/linux-x86

# Skip download if exists
if [ ! -f "$CLANG_VER/bin/clang" ]; then
    echo "Downloading Clang..."
    curl -L "${CLANG_URL}" | tar -xz -C $CLANG_VER
else
    echo "Clang already exists, skipping download."
fi

# Symlink
rm -rf clang-r416183b
ln -sf $CLANG_VER clang-r416183b

# =========================================================
# 6. SETUP KSU-NEXT & SUSFS
# =========================================================
echo -e "\n${GREEN}=== [5/9] Setup KSU-Next & SUSFS ===${NC}"
cd "$WORK_DIR/common"

# Reset git to clean state
git reset --hard HEAD
git clean -fd

echo "Installing KernelSU-Next..."
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s dev

echo "Cloning SUSFS..."
rm -rf sus
git clone https://gitlab.com/simonpunk/susfs4ksu/ -b gki-android12-5.10 sus
rm -rf sus/.git

echo "Copying SUSFS Patches..."
cp -r sus/kernel_patches/fs/* fs/
cp -r sus/kernel_patches/include/* include/
cp sus/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch .

echo "Applying Patch..."
# Apply patch with fallback to ignore minor conflicts
patch -p1 < 50_add_susfs_in_gki-android12-5.10.patch || echo "${YELLOW}Warning: Patch might be already applied or has minor conflicts.${NC}"

# =========================================================
# 7. APPLY MANUAL FIXES
# =========================================================
echo -e "\n${GREEN}=== [6/9] Apply Manual Fixes ===${NC}"
cd "$WORK_DIR/common"

# Stack Protector Fix
sed -i '/config STACKPROTECTOR_PER_TASK/{n;s/def_bool y/bool "Stack Protector per task"\n\tdefault y/;}' arch/arm64/Kconfig

# Xiaomi Version Check Bypass
sed -i '/pr_warn.*disagrees about version of symbol.*/,+1 s/.*/return 1;/' kernel/module.c

# DRM Atomic Fixes
sed -i '/^static int drm_atomic_check_valid_clones/,/^}/d' drivers/gpu/drm/drm_atomic_helper.c
sed -i '/ret = drm_atomic_check_valid_clones/,/return ret;/d' drivers/gpu/drm/drm_atomic_helper.c

# Rama Fixes (Fetch & Apply)
echo "Applying Rama Fixes..."
curl -L "https://github.com/ramabondanp/android_kernel_common-5.10/commit/4fe04b60009e.patch" | patch -p1 -N || echo "${YELLOW}Rama fix patch skipped (maybe applied already)${NC}"

# =========================================================
# 8. INJECT CONFIGURATION
# =========================================================
echo -e "\n${GREEN}=== [7/9] Inject Configuration ===${NC}"
cd "$WORK_DIR"
DEFCONFIG="common/arch/arm64/configs/gki_defconfig"

# Disable check_defconfig to prevent errors with custom configs
sed -i 's/check_defconfig//' common/build.config.gki

# Append user config
cat <<EOT >> $DEFCONFIG
CONFIG_KSU=y
CONFIG_KPM=n
CONFIG_KSU_MANUAL_HOOK=n
CONFIG_KSU_TRACEPOINT_HOOK=n
CONFIG_KSU_KPROBES_HOOK=y
# CONFIG_KSU_DEBUG is not set
# CONFIG_KSU_MULTI_MANAGER_SUPPORT is not set
# CONFIG_KSU_ALLOWLIST_WORKAROUND is not set
# CONFIG_KSU_CMDLINE is not set
CONFIG_KSU_LSM_SECURITY_HOOKS=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_SU=n
# CONFIG_STACKPROTECTOR_PER_TASK is not set
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_DEFAULT_BBR=y
CONFIG_HZ_300=y
CONFIG_HZ=300
EOT

# =========================================================
# 9. SET KERNEL VERSION
# =========================================================
echo -e "\n${GREEN}=== [8/9] Set Kernel Version ===${NC}"
cd "$WORK_DIR/common"
echo "" > scripts/setlocalversion
chmod +x scripts/setlocalversion

# Modify Makefile
if grep -q '^EXTRAVERSION *=' Makefile; then
     sed -i "s/^EXTRAVERSION *=.*/EXTRAVERSION = -$KERNEL_NAME/" Makefile
else
     echo "EXTRAVERSION = -$KERNEL_NAME" >> Makefile
fi

# =========================================================
# 10. BUILD KERNEL
# =========================================================
echo -e "\n${GREEN}=== [9/9] STARTING BUILD... ===${NC}"
cd "$WORK_DIR"

# Setup CCACHE for faster rebuilds
export CC="ccache clang"
export USE_CCACHE=1
export CCACHE_DIR="$HOME/.ccache"
mkdir -p "$CCACHE_DIR"
ccache -M 10G

# Update build config with correct Clang version
sed -i "s/clang-r[0-9]*[a-z]*/${CLANG_VER}/g" common/build.config.gki.aarch64
sed -i "s/clang-r[0-9]*[a-z]*/${CLANG_VER}/g" common/build.config.common 2>/dev/null || true

# Execute Build
LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh -j$(nproc)

# =========================================================
# 11. FINISH
# =========================================================
IMAGE_PATH="$WORK_DIR/out/android12-5.10/common/arch/arm64/boot/Image"

echo -e "\n${BLUE}=================================================${NC}"
if [ -f "$IMAGE_PATH" ]; then
    echo -e "${GREEN}BUILD SUCCESS!${NC}"
    echo -e "Kernel Image Location: ${YELLOW}$IMAGE_PATH${NC}"
    echo -e "Please copy the 'Image' file for packing (AnyKernel3, etc)."
else
    echo -e "${RED}BUILD FAILED! Image not found.${NC}"
    exit 1
fi
echo -e "${BLUE}=================================================${NC}"
