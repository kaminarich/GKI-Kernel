#!/bin/bash
set -e

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

echo "Starting build for Kernel ${KERNEL_VERSION} with variant ${KSU_VARIANT}"

# 1. Prepare Environment
mkdir -p "${OUT_DIR}"
mkdir -p "${CLANG_DIR}"

# 2. Get Toolchain
echo "Downloading Toolchain..."
CLANG_URL=$(curl -s "https://api.github.com/repos/bachnxuan/aosp_clang_mirror/releases/latest" | grep "browser_download_url" | grep ".tar.gz" | cut -d '"' -f 4)
curl -L "${CLANG_URL}" | tar -xz -C "${CLANG_DIR}"
export PATH="${CLANG_DIR}/bin:${PATH}"

# 3. Get Kernel Source
if [ ! -d "${KERNEL_SRC}" ]; then
    echo "Cloning Kernel Source..."
    git clone --depth 1 -b "${BRANCH}" "${REPO_URL}" "${KERNEL_SRC}"
fi
cd "${KERNEL_SRC}"

# 4. Generate Patches (Panggil script patch generator di sini)
echo "Generating Patch Files..."
chmod +x ../scripts/patch_gen.sh
../scripts/patch_gen.sh
PATCH_DIR="../patches"

# 5. Apply Modifications
echo "Applying Modifications..."

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
    
    # Copy SuSFS patches to kernel (or apply logic here)
    # Applying the Generated Fixes for SuSFS
    git apply "${PATCH_DIR}/susfs/fixes.patch"
    
    ./scripts/config --file "arch/arm64/configs/${DEFCONFIG}" \
        -e KSU \
        -e KSU_SUSFS \
        -e KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT

elif [ "${KSU_VARIANT}" == "resukisu" ]; then
    echo "Integrating ReSukiSU (Manual Hook Mode)..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
    
    # Apply Manager Patches
    git apply "${PATCH_DIR}/ksu/managers.patch"
    
    # Apply Manual Hooks
    git apply "${PATCH_DIR}/hooks/manual_hook.patch"

    # Apply SuSFS Fixes (karena ReSukiSU butuh base SuSFS fixes kadang-kadang)
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
cd "${WORK_DIR}"
python3 scripts/abi_audit.py \
    "${KERNEL_SRC}/${ABI_FILE}" \
    "${OUT_DIR}/vmlinux.symvers" > "${OUT_DIR}/abi_report.txt"

echo "Build Complete."
