#!/bin/bash

# Nama Kernel Custom (Biarkan kosong jika tidak ingin custom name)
KERNEL_NAME="Aetherium3.3-Eclipse-KSN"

# Pilih Versi Clang: "19" atau "20"
# 19 = r536225
# 20 = r547379
CLANG_CHOICE="19"

# Direktori kerja (Akan membuat folder 'gki' di lokasi skrip ini dijalankan)
WORK_DIR="$(pwd)/gki"

# =========================================================
# MULAI SKRIP
# =========================================================

set -e # Berhenti jika ada error

echo "=== Memulai Build Script KSUN (Linux Local) ==="
echo "Kernel Name : ${KERNEL_NAME:-Default}"
echo "Clang Ver   : ${CLANG_CHOICE}"
echo "Work Dir    : ${WORK_DIR}"

# 1. Install Dependencies
echo -e "\n=== Installing Dependencies ==="
sudo apt update
sudo apt install -y git curl repo build-essential bc bison flex libssl-dev \
    libelf-dev python3 python3-pip unzip zip rsync libncurses-dev lld ccache

# Konfigurasi Git (Jika belum ada)
if [ -z "$(git config --global user.name)" ]; then
    git config --global user.name "kaminari"
    git config --global user.email "itawanri14@gmail.com"
fi

# 2. Initialize Repo
echo -e "\n=== Initializing Repo ==="
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Cek apakah sudah pernah repo init, jika belum, jalankan
if [ ! -d ".repo" ]; then
    echo "Initializing Google repository..."
    repo init -u https://android.googlesource.com/kernel/manifest -b common-android12-5.10 --depth=1
fi

echo "Syncing repo..."
repo sync -c --no-tags --no-clone-bundle --optimized-fetch -j$(nproc --all)

# 3. Swap Kernel Source
# (Bagian ini dikomentari sesuai script terakhir kamu)
#echo -e "\n=== Swapping Kernel Source (MillenniumOSS) ==="
# Hapus source bawaan Google jika ada (dan jika belum diganti)
#if [ -d "common" ]; then
#    echo "Removing existing common directory to ensure clean swap..."
#    rm -rf common
#fi

#echo "Cloning MillenniumOSS..."
#git clone https://github.com/MillenniumOSS/android_kernel_common_android12-5.10.git common

# 4. Setup Clang
echo -e "\n=== Setting up Clang ==="
mkdir -p prebuilts-master/clang/host/linux-x86

if [ "$CLANG_CHOICE" == "19" ]; then
    echo "Selected: Clang 19 (r536225)"
    CLANG_VER="clang-r536225"
    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main-kernel-2025/clang-r536225.tar.gz"
else
    echo "Selected: Clang 20 (r547379)"
    CLANG_VER="clang-r547379"
    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/62cdcefa89e31af2d72c366e8b5ef8db84caea62/clang-r547379.tar.gz"
fi

mkdir -p prebuilts-master/clang/host/linux-x86/$CLANG_VER
cd prebuilts-master/clang/host/linux-x86
# Download hanya jika folder kosong atau user ingin memaksa (logic sederhana: timpa saja)
curl -L "${CLANG_URL}" | tar -xz -C $CLANG_VER

# Fix symlink
rm -rf clang-r416183b
ln -sf $CLANG_VER clang-r416183b

# Kembali ke root kerja
cd "$WORK_DIR/common"

# 5. Setup KernelSU-Next & SUSFS
echo -e "\n=== Setting up KernelSU-Next & SUSFS ==="
echo "Installing KernelSU-Next (Dev Profile)..."
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s dev

if [ -d "sus" ]; then rm -rf sus; fi
echo "Cloning SUSFS..."
git clone https://gitlab.com/simonpunk/susfs4ksu/ -b gki-android12-5.10 sus
rm -rf sus/.git

echo "Applying SUSFS patches..."
cp -r sus/kernel_patches/fs/* fs/
cp -r sus/kernel_patches/include/* include/
cp sus/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch .

# Apply patch dengan error handling (jika sudah ter-apply, lanjut saja)
patch -p1 < 50_add_susfs_in_gki-android12-5.10.patch || echo "Info: Patch might be already applied or failed."

# 6. Apply Manual Fixes
echo -e "\n=== Applying Manual Fixes ==="

# Fix Stack Protector
sed -i '/config STACKPROTECTOR_PER_TASK/{n;s/def_bool y/bool "Stack Protector per task"\n\tdefault y/;}' arch/arm64/Kconfig

# Bypass Xiaomi Module Version Check
sed -i '/pr_warn.*disagrees about version of symbol.*/,+1 s/.*/return 1;/' kernel/module.c

# Fix DRM Atomic Check
sed -i '/^static int drm_atomic_check_valid_clones/,/^}/d' drivers/gpu/drm/drm_atomic_helper.c
sed -i '/ret = drm_atomic_check_valid_clones/,/return ret;/d' drivers/gpu/drm/drm_atomic_helper.c

# Cherry-Pick Fixes from Rama
echo "Cherry-picking common fixes..."
curl -L "https://github.com/ramabondanp/android_kernel_common-5.10/commit/4fe04b60009e.patch" | git am -3 || {
    echo "Git am failed, trying regular patch..."
    curl -L "https://github.com/ramabondanp/android_kernel_common-5.10/commit/4fe04b60009e.patch" | patch -p1
}

# 7. Inject Configuration
echo -e "\n=== Injecting Defconfig ==="
cd "$WORK_DIR"
DEFCONFIG="common/arch/arm64/configs/gki_defconfig"

# Disable check_defconfig
sed -i 's/check_defconfig//' common/build.config.gki


cat <<EOT >> $DEFCONFIG
CONFIG_KSU=y
CONFIG_KPM=n
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_TRACEPOINT_HOOK=n
CONFIG_KSU_KPROBES_HOOK=n
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

# 8. Set Kernel Version
echo -e "\n=== Setting Kernel Version ==="
cd "$WORK_DIR/common"

# Buat script setlocalversion dummy
echo "" > scripts/setlocalversion
chmod +x scripts/setlocalversion

if [ -n "$KERNEL_NAME" ]; then
    if grep -q '^EXTRAVERSION *=' Makefile; then
        sed -i "s/^EXTRAVERSION *=.*/EXTRAVERSION = -$KERNEL_NAME/" Makefile
    else
        echo "EXTRAVERSION = -$KERNEL_NAME" >> Makefile
    fi
fi

# 9. Build Kernel
echo -e "\n=== Starting Build ==="
cd "$WORK_DIR"

export CC="ccache clang"
export USE_CCACHE=1
export CCACHE_DIR="$HOME/.ccache" # Menggunakan home directory user
mkdir -p "$CCACHE_DIR"
ccache -M 10G

# Update build config
sed -i "s/clang-r[0-9]*[a-z]*/${CLANG_VER}/g" common/build.config.gki.aarch64
sed -i "s/clang-r[0-9]*[a-z]*/${CLANG_VER}/g" common/build.config.common 2>/dev/null || true

# Command Build
LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh -j$(nproc)

# 10. Selesai & Upload (Opsional)
echo -e "\n=== Build Finished ==="

IMAGE_PATH="$WORK_DIR/out/android12-5.10/common/arch/arm64/boot/Image"

if [ -f "$IMAGE_PATH" ]; then
    echo "Image built successfully at: $IMAGE_PATH"
    
    # Upload ke PixelDrain (Opsional, uncomment jika mau otomatis upload)
    echo "Uploading to PixelDrain..."
    curl -u :23c84c82-ce06-4e35-bc1f-69eaa13b9958 \
      -F file=@"$IMAGE_PATH" \
      https://pixeldrain.com/api/file
else
    echo "Error: Image not found!"
    exit 1
fi
