#!/bin/bash
set -e

# ==============================================================================
# FUNGSI TELEGRAM NOTIFIKASI
# ==============================================================================
tg_send() {
    if [ ! -z "${TG_BOT_TOKEN}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d text="$1" \
        -d parse_mode="Markdown" \
        -d disable_web_page_preview=true > /dev/null
    fi
}

# ==============================================================================
# KONFIGURASI PATH & VARIABLE
# ==============================================================================
WORK_DIR=$(pwd)
OUT_DIR="${WORK_DIR}/out"
CLANG_DIR="${WORK_DIR}/clang"
KERNEL_SRC="${WORK_DIR}/android_kernel"
PATCH_DIR="${WORK_DIR}/patches" # Path patch absolut biar gak nyasar

# Tentukan URL & Branch berdasarkan versi kernel
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
        echo "❌ Error: Invalid kernel version."
        exit 1
        ;;
esac

# ==============================================================================
# MULAI PROSES
# ==============================================================================
echo "Starting build for Kernel ${KERNEL_VERSION}"
echo "Variant: ${KSU_VARIANT}"
echo "Clang: ${CLANG_SOURCE}"

tg_send "🚀 *GKI Build Started*
Kernel: \`${KERNEL_VERSION}\`
Variant: \`${KSU_VARIANT}\`
Clang: \`${CLANG_SOURCE}\`"

# 1. Siapkan Folder
mkdir -p "${OUT_DIR}"
mkdir -p "${CLANG_DIR}"

# 2. Generate Patches (PENTING: Lakukan di Root Dir)
echo "Generating Patch Files..."
cd "${WORK_DIR}"
if [ -f "scripts/patch_gen.sh" ]; then
    chmod +x scripts/patch_gen.sh
    ./scripts/patch_gen.sh
else
    echo "❌ Error: scripts/patch_gen.sh not found!"
    exit 1
fi

# 3. Download Toolchain (Clang)
echo "Downloading Toolchain (${CLANG_SOURCE})..."
cd "${WORK_DIR}"
if [ -f "scripts/clang_helper.sh" ]; then
    chmod +x scripts/clang_helper.sh
    CLANG_URL=$(./scripts/clang_helper.sh "${CLANG_SOURCE}")
else
    echo "❌ Error: scripts/clang_helper.sh not found!"
    exit 1
fi

if [ "$CLANG_URL" == "ERROR_INVALID_CLANG" ] || [ -z "$CLANG_URL" ]; then
    echo "❌ Error: Failed to fetch Clang URL for ${CLANG_SOURCE}"
    tg_send "❌ Build Failed: Invalid Clang Source"
    exit 1
fi

echo "Downloading from: $CLANG_URL"

# Ekstrak Clang sesuai ekstensi file
if [[ "$CLANG_URL" == *".tar.zst" ]]; then
    curl -L "$CLANG_URL" | tar -I zstd -x -C "${CLANG_DIR}"
elif [[ "$CLANG_URL" == *".tar.xz" ]]; then
    curl -L "$CLANG_URL" | tar -xJ -C "${CLANG_DIR}"
elif [[ "$CLANG_URL" == *".tar.gz" ]] || [[ "$CLANG_URL" == *".tgz" ]]; then
    curl -L "$CLANG_URL" | tar -xz -C "${CLANG_DIR}"
else
    curl -L "$CLANG_URL" | tar -x -C "${CLANG_DIR}"
fi

# Set PATH
export PATH="${CLANG_DIR}/bin:${PATH}"

# 4. Clone Kernel Source
if [ ! -d "${KERNEL_SRC}" ]; then
    echo "Cloning Kernel Source..."
    git clone --depth 1 -b "${BRANCH}" "${REPO_URL}" "${KERNEL_SRC}"
fi
cd "${KERNEL_SRC}"

# ==============================================================================
# MODIFIKASI KERNEL (Dirty Hacks & Variants)
# ==============================================================================
echo "Applying Modifications..."

# --- Dirty Hacks (Wajib buat GKI Booting) ---
echo "[+] Applying Dirty Hacks..."
# 1. Bypass Module Version Check
sed -i '/pr_warn.*disagrees about version of symbol.*/,+1 s/.*/return 1;/' kernel/module.c
# 2. Fix DRM Display (Cek file dulu karena path bisa beda)
if [ -f drivers/gpu/drm/drm_atomic_helper.c ]; then
    sed -i '/^static int drm_atomic_check_valid_clones/,/^}/d' drivers/gpu/drm/drm_atomic_helper.c
    sed -i '/ret = drm_atomic_check_valid_clones/,/return ret;/d' drivers/gpu/drm/drm_atomic_helper.c
fi

# --- Base Config ---
./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" \
    -e LTO_CLANG_THIN \
    -d LTO_NONE \
    -e BUILD_ARM64_DT_OVERLAY

# --- Variant Logic ---
if [ "${KSU_VARIANT}" == "standard" ]; then
    echo "[+] Integrating Standard KernelSU..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
    ./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" -e KSU

elif [ "${KSU_VARIANT}" == "susfs" ]; then
    echo "[+] Integrating KernelSU + SuSFS..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
    
    # Clone SuSFS Repo
    if [ ! -d "../susfs4ksu" ]; then
        git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git ../susfs4ksu
    fi
    
    # Apply SuSFS Patches (Pake --ignore-whitespace biar aman)
    # Patch ini dibuat oleh patch_gen.sh di folder PATCH_DIR
    git apply --ignore-whitespace "${PATCH_DIR}/susfs/fixes.patch"
    
    # Config SuSFS
    ./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" \
        -e KSU \
        -e KSU_SUSFS \
        -e KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT

elif [ "${KSU_VARIANT}" == "resukisu" ]; then
    echo "[+] Integrating ReSukiSU (Manual Hook Mode)..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
    
    # Apply Manager Support, Manual Hooks & SuSFS Fixes
    # Menggunakan path absolut PATCH_DIR
    git apply --ignore-whitespace "${PATCH_DIR}/ksu/managers.patch"
    git apply --ignore-whitespace "${PATCH_DIR}/hooks/manual_hook.patch"
    # ReSukiSU juga butuh base fixes dari SuSFS
    git apply --ignore-whitespace "${PATCH_DIR}/susfs/fixes.patch"

    # Config ReSukiSU (Disable Kprobes, Enable Manual Hook via code patching)
    ./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" \
        -e KSU \
        -e KSU_SUSFS \
        -d KSU_KPROBES \
        -d KSU_KPROBE_EVENTS
fi

# ==============================================================================
# PROSES BUILD
# ==============================================================================
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

# ==============================================================================
# VERIFIKASI ABI
# ==============================================================================
echo "Running ABI Verification..."
cd "${WORK_DIR}"

if [ -f "scripts/abi_audit.py" ]; then
    python3 scripts/abi_audit.py \
        "${KERNEL_SRC}/${ABI_FILE}" \
        "${OUT_DIR}/vmlinux.symvers" > "${OUT_DIR}/abi_report.txt"
else
    echo "⚠️ Warning: scripts/abi_audit.py not found, skipping ABI check."
    echo "ABI Check Skipped" > "${OUT_DIR}/abi_report.txt"
fi

echo "Build Complete."
tg_send "✅ *GKI Build Finished*
Status: Success
Kernel: ${KERNEL_VERSION}
Variant: ${KSU_VARIANT}"
