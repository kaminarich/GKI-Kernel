#!/bin/bash
set -e

# --- Telegram Function ---
tg_send() {
    if [ ! -z "${TG_BOT_TOKEN}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d text="$1" \
        -d parse_mode="Markdown" \
        -d disable_web_page_preview=true > /dev/null
    fi
}

# Configuration
WORK_DIR=$(pwd)
OUT_DIR="${WORK_DIR}/out"
CLANG_DIR="${WORK_DIR}/clang"
KERNEL_SRC="${WORK_DIR}/android_kernel"

# Set source URLs
case "${KERNEL_VERSION}" in
    "5.10")
        REPO_URL="https://android.googlesource.com/kernel/common"
        BRANCH="android12-5.10-lts"
        DEFCONFIG="gki_defconfig"
        ABI_FILE="android/abi_gki_aarch64.xml"
        ;;
    "6.1")
        REPO_URL="https://android.googlesource.com/kernel/common"
        BRANCH="android14-6.1-lts"
        DEFCONFIG="gki_defconfig"
        ABI_FILE="android/abi_gki_aarch64.stg"
        ;;
    "6.6")
        REPO_URL="https://android.googlesource.com/kernel/common"
        BRANCH="android14-6.6-lts"
        DEFCONFIG="gki_defconfig"
        ABI_FILE="android/abi_gki_aarch64.stg"
        ;;
    *)
        echo "Error: Invalid kernel version."
        exit 1
        ;;
esac

echo "Starting build for Kernel ${KERNEL_VERSION}"
echo "Variant: ${KSU_VARIANT}"
echo "Clang: ${CLANG_SOURCE}"

tg_send "🚀 *GKI Build Started*
Kernel: ${KERNEL_VERSION}
Variant: ${KSU_VARIANT}
Clang: ${CLANG_SOURCE}"

# 1. Prepare Environment
mkdir -p "${OUT_DIR}"
mkdir -p "${CLANG_DIR}"

# 2. Get Toolchain (UPDATED PATH FIX)
echo "Downloading Toolchain (${CLANG_SOURCE})..."
# Menggunakan path absolute WORK_DIR karena belum pindah directory
chmod +x "${WORK_DIR}/scripts/clang_helper.sh"
CLANG_URL=$("${WORK_DIR}/scripts/clang_helper.sh" "${CLANG_SOURCE}")

if [ "$CLANG_URL" == "ERROR_INVALID_CLANG" ] || [ -z "$CLANG_URL" ]; then
    echo "❌ Error: Failed to fetch Clang URL for ${CLANG_SOURCE}"
    tg_send "❌ Build Failed: Invalid Clang Source"
    exit 1
fi

echo "Downloading from: $CLANG_URL"

if [[ "$CLANG_URL" == *".tar.zst" ]]; then
    curl -L "$CLANG_URL" | tar -I zstd -x -C "${CLANG_DIR}"
elif [[ "$CLANG_URL" == *".tar.xz" ]]; then
    curl -L "$CLANG_URL" | tar -xJ -C "${CLANG_DIR}"
elif [[ "$CLANG_URL" == *".tar.gz" ]] || [[ "$CLANG_URL" == *".tgz" ]]; then
    curl -L "$CLANG_URL" | tar -xz -C "${CLANG_DIR}"
else
    curl -L "$CLANG_URL" | tar -x -C "${CLANG_DIR}"
fi

export PATH="${CLANG_DIR}/bin:${PATH}"

# 3. Get Kernel Source
if [ ! -d "${KERNEL_SRC}" ]; then
    echo "Cloning Kernel Source..."
    git clone --depth 1 -b "${BRANCH}" "${REPO_URL}" "${KERNEL_SRC}"
fi
cd "${KERNEL_SRC}"

# 4. Generate Patches
echo "Generating Patch Files..."
# Di sini kita sudah di dalam folder kernel, jadi pakai ../scripts/ itu BENAR
chmod +x ../scripts/patch_gen.sh
../scripts/patch_gen.sh
PATCH_DIR="../patches"

# 5. Apply Modifications
echo "Applying Modifications..."

# Dirty Hacks
sed -i '/pr_warn.*disagrees about version of symbol.*/,+1 s/.*/return 1;/' kernel/module.c
if [ -f drivers/gpu/drm/drm_atomic_helper.c ]; then
    sed -i '/^static int drm_atomic_check_valid_clones/,/^}/d' drivers/gpu/drm/drm_atomic_helper.c
    sed -i '/ret = drm_atomic_check_valid_clones/,/return ret;/d' drivers/gpu/drm/drm_atomic_helper.c
fi

# Base Config
./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" \
    -e LTO_CLANG_THIN \
    -d LTO_NONE \
    -e BUILD_ARM64_DT_OVERLAY

if [ "${KSU_VARIANT}" == "standard" ]; then
    echo "Integrating Standard KernelSU..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
    ./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" -e KSU

elif [ "${KSU_VARIANT}" == "susfs" ]; then
    echo "Integrating KernelSU + SuSFS..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
    
    # Clone SuSFS
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git ../susfs4ksu
    
    # Apply SuSFS patches
    git apply "${PATCH_DIR}/susfs/fixes.patch"
    
    ./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" \
        -e KSU \
        -e KSU_SUSFS \
        -e KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT

elif [ "${KSU_VARIANT}" == "resukisu" ]; then
    echo "Integrating ReSukiSU (Manual Hook Mode)..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
    
    # Apply Manager & Manual Hook Patches
    git apply "${PATCH_DIR}/ksu/managers.patch"
    git apply "${PATCH_DIR}/hooks/manual_hook.patch"
    git apply "${PATCH_DIR}/susfs/fixes.patch"

    ./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" \
        -e KSU \
        -e KSU_SUSFS \
        -d KSU_KPROBES \
        -d KSU_KPROBE_EVENTS
fi

# 6. Build
echo "Building Kernel..."
make -j$(nproc) \
    O="${OUT_DIR}" \
    ARCH=arm64 \
    CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
    "${DEFCONFIG}"

make -j$(nproc) \
    O="${OUT_DIR}" \
    ARCH=arm64 \
    CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
    Image

# 7. Run ABI Check
echo "Running ABI Verification..."
# Pindah balik ke WORK_DIR sebelum jalanin script python
cd "${WORK_DIR}"
python3 scripts/abi_audit.py \
    "${KERNEL_SRC}/${ABI_FILE}" \
    "${OUT_DIR}/vmlinux.symvers" > "${OUT_DIR}/abi_report.txt"

echo "Build Complete."
tg_send "✅ *GKI Build Finished*
Status: Success"
