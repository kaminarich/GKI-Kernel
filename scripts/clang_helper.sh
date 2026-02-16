#!/bin/bash

# Repositories
SLIM_REPO="https://www.kernel.org/pub/tools/llvm/files/"
RV_REPO="https://api.github.com/repos/Rv-Project/RvClang/releases/latest"
AOSP_REPO="https://api.github.com/repos/bachnxuan/aosp_clang_mirror/releases/latest"
YUKI_REPO="https://api.github.com/repos/Klozz/Yuki_clang_releases/releases/latest"
LILIUM_REPO="https://api.github.com/repos/liliumproject/clang/releases/latest"
TNF_REPO="https://api.github.com/repos/topnotchfreaks/clang/releases/latest"
NEUTRON_REPO="https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest"
MANDISA_REPO="https://api.github.com/repos/Mandi-Sa/clang/releases/latest"
DV_REPO="https://api.github.com/repos/xaverodumpster/dv_clang/releases/latest"

get_url() {
  local url="$1"
  local filter="$2"
  [ -z "$filter" ] && filter=".tar.gz"
  
  # Logic: Curl JSON -> Grep url -> grep extension -> cut link
  curl -s "$url" | grep "browser_download_url" | grep "$filter" | head -n 1 | cut -d '"' -f 4
}

case "$1" in
  "slim")
    # Slim logic beda sendiri (HTML parsing simple)
    curl -s "$SLIM_REPO" | grep -oP 'llvm-[\d.]+-x86_64\.tar\.xz' | sort -V | tail -n1 | sed "s|^|$SLIM_REPO|"
    ;;
  "rv")
    get_url "$RV_REPO"
    ;;
  "aosp")
    get_url "$AOSP_REPO"
    ;;
  "yuki")
    get_url "$YUKI_REPO"
    ;;
  "lilium")
    get_url "$LILIUM_REPO"
    ;;
  "tnf")
    get_url "$TNF_REPO"
    ;;
  "neutron")
    get_url "$NEUTRON_REPO" ".tar.zst"
    ;;
  "mandi-sa")
    # Mandi-sa kadang pake 7z atau tar.gz, kita coba ambil yg ada
    get_url "$MANDISA_REPO"
    ;;
  "dv")
    get_url "$DV_REPO" ".xz"
    ;;
  *)
    echo "ERROR_INVALID_CLANG"
    exit 1
    ;;
esac

