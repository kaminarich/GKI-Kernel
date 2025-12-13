#!/bin/bash

# =========================================================
# KONFIGURASI
# =========================================================
# Variabel ini akan di-inject dari GitHub Actions (YAML)
KERNEL_NAME="${KERNEL_NAME:-GKI-KSUN}"
CLANG_CHOICE="${CLANG_CHOICE:-20}"
WORK_DIR="$(pwd)/gki"

set -e

echo "=== STARTING CLEAN GKI BUILD SCRIPT ==="

# 1. Install Dependencies
echo -e "\n=== 1. Install Dependencies & Setup Git ==="
sudo apt update
sudo apt install -y git curl repo build-essential bc bison flex libssl-dev \
  libelf-dev python3 python3-pip unzip zip rsync libncurses-dev lld ccache

git config --global user.name "kaminari"
git config --global user.email "itawanri14@gmail.com"

# 2. Repo Init & Sync (Murni Google)
echo -e "\n=== 2. Initialize Repo (Google Structure) ==="
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [ ! -d ".repo" ]; then
    repo init -u https://android.googlesource.com/kernel/manifest -b common-android12-5.10 --depth=1
fi
# Ini akan mengambil source code Google murni (common)
repo sync -c --no-tags --no-clone-bundle --optimized-fetch -j$(nproc --all)

# 3. Setup Clang
echo -e "\n=== 3. Setup Clang ==="
mkdir -p prebuilts-master/clang/host/linux-x86

if [ "$CLANG_CHOICE" == "19" ]; then
    CLANG_VER="clang-r536225"
    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main-kernel-2025/clang-r536225.tar.gz"
else
    CLANG_VER="clang-r547379"
    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/62cdcefa89e31af2d72c366e8b5ef8db84caea62/clang-r547379.tar.gz"
fi

mkdir -p prebuilts-master/clang/host/linux-x86/$CLANG_VER
cd prebuilts-master/clang/host/linux-x86
curl -L "${CLANG_URL}" | tar -xz -C $CLANG_VER
rm -rf clang-r416183b
ln -sf $CLANG_VER clang-r416183b

# 4. Setup KSU & SUSFS
echo -e "\n=== 4. Setup KSU-Next & SUSFS ==="
cd "$WORK_DIR/common"
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s dev

# Karena tidak ada MillenniumOSS, kita clone SUSFS ke sini
rm -rf sus
git clone https://gitlab.com/simonpunk/susfs4ksu/ -b gki-android12-5.10 sus
rm -rf sus/.git

# Aplikasi patch SUSFS (Manual seperti sebelumnya)
cp -r sus/kernel_patches/fs/* fs/
cp -r sus/kernel_patches/include/* include/
cp sus/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch .
patch -p1 < 50_add_susfs_in_gki-android12-5.10.patch || echo "Patch applied/skipped"

# 5. Apply Manual Fixes (Hanya yang paling kritis/umum)
echo -e "\n=== 5. Apply Manual Fixes (Minimal) ==="
cd "$WORK_DIR/common"

# Fix Stack Protector logic
sed -i '/config STACKPROTECTOR_PER_TASK/{n;s/def_bool y/bool "Stack Protector per task"\n\tdefault y/;}' arch/arm64/Kconfig

# 6. Inject Config & FIX MODULE ERROR (Paling Kritis)
echo -e "\n=== 6. Inject Configuration & FIX Module List Error ==="
cd "$WORK_DIR"
DEFCONFIG="common/arch/arm64/configs/gki_defconfig"

# --- FIX WAJIB: BUNUH PENGECEKAN DAFTAR MODULE ---
# Ini mencegah error 'modules list out of date' yang menyebabkan build gagal
sed -i '/MODULES_LIST/d' common/build.config.gki
sed -i '/MODULES_LIST/d' common/build.config.gki.aarch64
# ---------------------------------------------------

# Disable check_defconfig (Wajib agar konfigurasi custom di bawah bisa masuk)
sed -i 's/check_defconfig//' common/build.config.gki

cat <<EOT >> $DEFCONFIG
CONFIG_KSU=y
CONFIG_KPM=n
CONFIG_KSU_SUSFS=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_KPROBES_HOOK=n
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

# 7. Set Version
echo -e "\n=== 7. Set Kernel Version ==="
cd "$WORK_DIR/common"
echo "" > scripts/setlocalversion
chmod +x scripts/setlocalversion
if [ -n "$KERNEL_NAME" ]; then
    if grep -q '^EXTRAVERSION *=' Makefile; then
        sed -i "s/^EXTRAVERSION *=.*/EXTRAVERSION = -$KERNEL_NAME/" Makefile
    else
        echo "EXTRAVERSION = -$KERNEL_NAME" >> Makefile
    fi
fi

# 8. Build
echo -e "\n=== 8. Build Kernel ==="
cd "$WORK_DIR"
export CC="ccache clang"
export USE_CCACHE=1
export CCACHE_DIR="$HOME/.ccache"
mkdir -p "$CCACHE_DIR"
ccache -M 5G

# Update build config clang version
sed -i "s/clang-r[0-9]*[a-z]*/${CLANG_VER}/g" common/build.config.gki.aarch64
sed -i "s/clang-r[0-9]*[a-z]*/${CLANG_VER}/g" common/build.config.common 2>/dev/null || true

LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh -j$(nproc)

# 9. Check Output
echo -e "\n=== 9. Build Status ==="
IMAGE_PATH="$WORK_DIR/out/android12-5.10/common/arch/arm64/boot/Image"

if [ -f "$IMAGE_PATH" ]; then
    echo "SUCCESS: Image built at $IMAGE_PATH"
else
    echo "ERROR: Image failed to build"
    exit 1
fi
