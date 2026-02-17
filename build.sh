#!/bin/bash
#===============================================================================
# build.sh - CachyOS Kernel Build Script for Void Linux
#===============================================================================
# Builds Linux kernel 6.19.x with CachyOS patches and BORE scheduler
# Optimized for Intel i9-14900HX (Raptor Lake) with NVIDIA driver support
#
# Usage: ./build.sh [--clean] [--config-only]
#   --clean       Remove existing build directory before starting
#   --config-only Only configure, don't compile
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Version Configuration (update these for new releases)
#-------------------------------------------------------------------------------
KERNEL_MAJOR="6"
KERNEL_MINOR="19"
KERNEL_PATCH="2"  # Latest stable 6.19.x - check kernel.org for updates
KERNEL_VERSION="${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_PATCH}"
KERNEL_BASE="${KERNEL_MAJOR}.${KERNEL_MINOR}"

# CachyOS patches branch (matches kernel major.minor)
CACHYOS_PATCHES_BRANCH="${KERNEL_BASE}"
CACHYOS_PATCHES_URL="https://raw.githubusercontent.com/CachyOS/kernel-patches/master/${CACHYOS_PATCHES_BRANCH}"

# Kernel source
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION}.tar.xz"

#-------------------------------------------------------------------------------
# Build Configuration
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
KERNEL_DIR="${BUILD_DIR}/linux-${KERNEL_VERSION}"
PATCHES_DIR="${BUILD_DIR}/patches-${KERNEL_BASE}"
NPROC=$(nproc)

# Use Clang/LLVM toolchain for LTO + AutoFDO + Propeller support
export LLVM=1
export CC=clang
MAKE_OPTS="LLVM=1 -j${NPROC}"

# AutoFDO profile (set by profile_and_rebuild.sh after profiling)
AUTOFDO_PROFILE="${SCRIPT_DIR}/autofdo.profdata"
PROPELLER_PROFILE="${SCRIPT_DIR}/propeller"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# CachyOS Patches to Apply
#-------------------------------------------------------------------------------
# These patches are from CachyOS kernel-patches repository
# Order matters - apply in this sequence
PATCHES=(
    "0001-amd-isp4.patch"
    "0002-bbr3.patch"
    "0003-cachy.patch"
    "0004-fixes.patch"
    "0005-t2.patch"
    "0006-vesa-dsc-bpp.patch"
    "0007-vmscape.patch"
)

# BORE scheduler patch (separate from main patches)
BORE_PATCH="sched/0001-bore-cachy.patch"

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_dependencies() {
    log_info "Checking build dependencies..."
    local deps=(wget tar xz gcc make flex bison bc libelf ncurses openssl perl)
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null && ! pkg-config --exists "$dep" 2>/dev/null; then
            # Check if it's a library
            if [[ "$dep" == "libelf" ]] && ! pkg-config --exists libelf 2>/dev/null; then
                missing+=("elfutils-devel")
            elif [[ "$dep" == "ncurses" ]] && ! pkg-config --exists ncurses 2>/dev/null; then
                missing+=("ncurses-devel")
            elif [[ "$dep" == "openssl" ]] && ! pkg-config --exists openssl 2>/dev/null; then
                missing+=("openssl-devel")
            fi
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Some dependencies may be missing. Install with:"
        echo "  sudo xbps-install -S ${missing[*]} base-devel"
    fi
    
    log_success "Dependency check complete"
}

cleanup_old_build() {
    if [[ -d "${KERNEL_DIR}" ]]; then
        log_info "Removing old kernel build directory..."
        rm -rf "${KERNEL_DIR}"
    fi
    if [[ -d "${PATCHES_DIR}" ]]; then
        log_info "Removing old patches directory..."
        rm -rf "${PATCHES_DIR}"
    fi
}

#-------------------------------------------------------------------------------
# Download Functions
#-------------------------------------------------------------------------------
download_kernel() {
    local tarball="${BUILD_DIR}/linux-${KERNEL_VERSION}.tar.xz"
    
    mkdir -p "${BUILD_DIR}"
    
    if [[ -f "${tarball}" ]]; then
        log_info "Kernel tarball already exists, skipping download"
    else
        log_info "Downloading Linux ${KERNEL_VERSION}..."
        wget -q --show-progress -O "${tarball}" "${KERNEL_URL}" || \
            log_error "Failed to download kernel from ${KERNEL_URL}"
    fi
    
    if [[ ! -d "${KERNEL_DIR}" ]]; then
        log_info "Extracting kernel source..."
        tar -xf "${tarball}" -C "${BUILD_DIR}" || \
            log_error "Failed to extract kernel tarball"
    fi
    
    log_success "Kernel source ready at ${KERNEL_DIR}"
}

download_patches() {
    mkdir -p "${PATCHES_DIR}"
    
    log_info "Downloading CachyOS patches for kernel ${KERNEL_BASE}..."
    
    # Download main patches
    for patch in "${PATCHES[@]}"; do
        local patch_file="${PATCHES_DIR}/${patch}"
        if [[ ! -f "${patch_file}" ]]; then
            log_info "  Downloading ${patch}..."
            if ! wget -q -O "${patch_file}" "${CACHYOS_PATCHES_URL}/${patch}" 2>/dev/null; then
                log_warn "  Failed to download ${patch} - may not exist for ${KERNEL_BASE}"
                rm -f "${patch_file}"
            fi
        fi
    done
    
    # Download BORE scheduler patch
    local bore_file="${PATCHES_DIR}/bore-cachy.patch"
    if [[ ! -f "${bore_file}" ]]; then
        log_info "  Downloading BORE scheduler patch..."
        if ! wget -q -O "${bore_file}" "${CACHYOS_PATCHES_URL}/${BORE_PATCH}" 2>/dev/null; then
            log_warn "  Failed to download BORE patch - trying alternative location"
            # Try alternative location
            if ! wget -q -O "${bore_file}" "${CACHYOS_PATCHES_URL}/sched/0001-bore.patch" 2>/dev/null; then
                log_warn "  BORE patch not available for ${KERNEL_BASE}"
                rm -f "${bore_file}"
            fi
        fi
    fi
    
    # Download POC idle CPU selector patch (faster wakeup latency)
    local poc_file="${PATCHES_DIR}/poc-selector.patch"
    if [[ ! -f "${poc_file}" ]]; then
        log_info "  Downloading POC selector patch..."
        wget -q -O "${poc_file}" "${CACHYOS_PATCHES_URL}/misc/poc-selector.patch" 2>/dev/null || \
            { log_warn "  Failed to download POC selector patch"; rm -f "${poc_file}"; }
    fi

    # Download NVIDIA compile fix patches for 6.19+
    local nvidia_patches_dir="${PATCHES_DIR}/nvidia"
    mkdir -p "${nvidia_patches_dir}"
    local nvidia_patches=(
        "misc/nvidia/0001-Enable-atomic-kernel-modesetting-by-default.patch"
        "misc/nvidia/0002-Add-IBT-support.patch"
        "misc/nvidia/0003-Fix-compile-for-6.19.patch"
    )
    for np in "${nvidia_patches[@]}"; do
        local np_base
        np_base=$(basename "${np}")
        local np_file="${nvidia_patches_dir}/${np_base}"
        if [[ ! -f "${np_file}" ]]; then
            log_info "  Downloading NVIDIA patch ${np_base}..."
            wget -q -O "${np_file}" "${CACHYOS_PATCHES_URL}/${np}" 2>/dev/null || \
                { log_warn "  Failed to download ${np_base}"; rm -f "${np_file}"; }
        fi
    done

    log_success "Patches downloaded to ${PATCHES_DIR}"
}

#-------------------------------------------------------------------------------
# Patch Application
#-------------------------------------------------------------------------------
apply_patches() {
    cd "${KERNEL_DIR}"
    
    log_info "Applying CachyOS patches..."
    
    # Apply main patches
    for patch in "${PATCHES[@]}"; do
        local patch_file="${PATCHES_DIR}/${patch}"
        if [[ -f "${patch_file}" && -s "${patch_file}" ]]; then
            log_info "  Applying ${patch}..."
            if ! patch -p1 -N --dry-run < "${patch_file}" &>/dev/null; then
                log_warn "  Patch ${patch} may already be applied or conflicts - skipping"
            else
                patch -p1 -N < "${patch_file}" || log_warn "  Failed to apply ${patch}"
            fi
        fi
    done
    
    # Apply BORE scheduler patch
    local bore_file="${PATCHES_DIR}/bore-cachy.patch"
    if [[ -f "${bore_file}" && -s "${bore_file}" ]]; then
        log_info "  Applying BORE scheduler patch..."
        if ! patch -p1 -N --dry-run < "${bore_file}" &>/dev/null; then
            log_warn "  BORE patch may already be applied or conflicts - skipping"
        else
            patch -p1 -N < "${bore_file}" || log_warn "  Failed to apply BORE patch"
        fi
    fi

    # Apply POC idle CPU selector patch (faster task wakeup)
    local poc_file="${PATCHES_DIR}/poc-selector.patch"
    if [[ -f "${poc_file}" && -s "${poc_file}" ]]; then
        log_info "  Applying POC selector patch..."
        if ! patch -p1 -N --dry-run < "${poc_file}" &>/dev/null; then
            log_warn "  POC selector patch may already be applied or conflicts - skipping"
        else
            patch -p1 -N < "${poc_file}" || log_warn "  Failed to apply POC selector patch"
        fi
    fi

    # NVIDIA 6.19 compile fixes are downloaded for DKMS reference
    log_info "  Note: NVIDIA 6.19 compile fixes downloaded for DKMS reference"
    
    log_success "Patches applied"
}

#-------------------------------------------------------------------------------
# Kernel Configuration
#-------------------------------------------------------------------------------
configure_kernel() {
    cd "${KERNEL_DIR}"
    
    log_info "Configuring kernel..."
    
    # Start with current running kernel config if available, otherwise defconfig
    if [[ -f /proc/config.gz ]]; then
        log_info "  Using current kernel config as base..."
        zcat /proc/config.gz > .config
    elif [[ -f "/boot/config-$(uname -r)" ]]; then
        log_info "  Using /boot config as base..."
        cp "/boot/config-$(uname -r)" .config
    else
        log_info "  Using defconfig as base..."
        make ${MAKE_OPTS} defconfig
    fi
    
    # Backup original config
    cp .config .config.original
    
    log_info "  Applying CachyOS/performance optimizations..."
    
    # Set local version suffix (shows in uname -r)
    ./scripts/config --set-str CONFIG_LOCALVERSION "-voltdev"
    
    #---------------------------------------------------------------------------
    # CPU Optimizations for Intel i9-14900HX (Raptor Lake)
    #---------------------------------------------------------------------------
    # Use native optimizations - compiler will detect Raptor Lake
    ./scripts/config --enable CONFIG_MNATIVE_INTEL 2>/dev/null || \
    ./scripts/config --set-str CONFIG_MARCH_NATIVE_INTEL y 2>/dev/null || \
    ./scripts/config --enable CONFIG_GENERIC_CPU
    
    # Processor family
    ./scripts/config --enable CONFIG_X86_64
    ./scripts/config --enable CONFIG_SMP
    ./scripts/config --set-val CONFIG_NR_CPUS 32
    
    # Disable 5-level paging (i9-14900HX has no LA57 support)
    ./scripts/config --disable CONFIG_X86_5LEVEL
    
    #---------------------------------------------------------------------------
    # Scheduler Configuration (BORE + Preemption)
    #---------------------------------------------------------------------------
    # Enable BORE scheduler if available
    ./scripts/config --enable CONFIG_SCHED_BORE 2>/dev/null || true
    ./scripts/config --set-val CONFIG_SCHED_BORE_BURST_PENALTY_SCALE 1280 2>/dev/null || true
    
    # Full preemption for low latency (gaming/desktop)
    ./scripts/config --enable CONFIG_PREEMPT
    ./scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
    ./scripts/config --disable CONFIG_PREEMPT_NONE
    
    # 1000Hz timer for responsiveness
    ./scripts/config --enable CONFIG_HZ_1000
    ./scripts/config --set-val CONFIG_HZ 1000
    ./scripts/config --disable CONFIG_HZ_100
    ./scripts/config --disable CONFIG_HZ_250
    ./scripts/config --disable CONFIG_HZ_300
    
    # Tickless idle (better power efficiency)
    ./scripts/config --enable CONFIG_NO_HZ_IDLE
    ./scripts/config --enable CONFIG_NO_HZ_COMMON

    # Hybrid CPU topology awareness (P-cores + E-cores on Raptor Lake)
    ./scripts/config --enable CONFIG_SCHED_MC
    ./scripts/config --enable CONFIG_SCHED_MC_PRIO
    ./scripts/config --enable CONFIG_SCHED_SMT
    ./scripts/config --enable CONFIG_SCHED_CLUSTER
    ./scripts/config --enable CONFIG_SCHED_AUTOGROUP
    
    #---------------------------------------------------------------------------
    # NVIDIA Driver Critical Options (REQUIRED for Vulkan/Ray Tracing)
    #---------------------------------------------------------------------------
    # These are CRITICAL for NVIDIA driver 580.x to work properly
    ./scripts/config --enable CONFIG_ZONE_DEVICE
    ./scripts/config --enable CONFIG_DEVICE_PRIVATE
    ./scripts/config --enable CONFIG_MEMORY_HOTPLUG
    ./scripts/config --enable CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE
    ./scripts/config --enable CONFIG_MEMORY_HOTREMOVE
    ./scripts/config --enable CONFIG_HMM_MIRROR
    ./scripts/config --enable CONFIG_MMU_NOTIFIER
    
    # DRM options for NVIDIA
    ./scripts/config --enable CONFIG_DRM
    ./scripts/config --enable CONFIG_DRM_KMS_HELPER
    ./scripts/config --module CONFIG_DRM_NOUVEAU  # Keep as module, NVIDIA replaces it
    ./scripts/config --enable CONFIG_DRM_FBDEV_EMULATION
    
    # Framebuffer support
    ./scripts/config --enable CONFIG_FB
    ./scripts/config --enable CONFIG_FB_EFI
    ./scripts/config --enable CONFIG_FB_VESA
    ./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
    
    #---------------------------------------------------------------------------
    # Memory Management Optimizations
    #---------------------------------------------------------------------------
    ./scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE
    ./scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS
    ./scripts/config --enable CONFIG_COMPACTION
    ./scripts/config --enable CONFIG_KSM
    
    # MGLRU (Multi-Gen LRU) for better memory management
    ./scripts/config --enable CONFIG_LRU_GEN 2>/dev/null || true
    ./scripts/config --enable CONFIG_LRU_GEN_ENABLED 2>/dev/null || true
    
    # ZRAM/ZSWAP compressed swap with zstd (~3x better ratio than lzo)
    ./scripts/config --enable CONFIG_ZSWAP
    ./scripts/config --enable CONFIG_ZSWAP_DEFAULT_ON
    ./scripts/config --enable CONFIG_ZSWAP_SHRINKER_DEFAULT_ON 2>/dev/null || true
    ./scripts/config --disable CONFIG_ZSWAP_COMPRESSOR_DEFAULT_LZO
    ./scripts/config --enable CONFIG_ZSWAP_COMPRESSOR_DEFAULT_ZSTD
    ./scripts/config --set-str CONFIG_ZSWAP_COMPRESSOR_DEFAULT "zstd"
    ./scripts/config --enable CONFIG_ZRAM
    ./scripts/config --disable CONFIG_ZRAM_BACKEND_FORCE_LZO 2>/dev/null || true
    ./scripts/config --enable CONFIG_ZRAM_BACKEND_ZSTD 2>/dev/null || true
    ./scripts/config --enable CONFIG_ZRAM_DEF_COMP_ZSTD 2>/dev/null || true
    ./scripts/config --disable CONFIG_ZRAM_DEF_COMP_LZORLE 2>/dev/null || true
    
    #---------------------------------------------------------------------------
    # I/O Scheduler
    #---------------------------------------------------------------------------
    ./scripts/config --enable CONFIG_MQ_IOSCHED_DEADLINE
    ./scripts/config --enable CONFIG_MQ_IOSCHED_KYBER
    ./scripts/config --enable CONFIG_BLK_CGROUP
    
    # BFQ scheduler
    ./scripts/config --enable CONFIG_IOSCHED_BFQ
    ./scripts/config --enable CONFIG_BFQ_GROUP_IOSCHED
    
    #---------------------------------------------------------------------------
    # Network Optimizations (BBR3)
    #---------------------------------------------------------------------------
    ./scripts/config --enable CONFIG_TCP_CONG_BBR 2>/dev/null || \
    ./scripts/config --enable CONFIG_TCP_CONG_BBR2 2>/dev/null || true
    ./scripts/config --set-str CONFIG_DEFAULT_TCP_CONG "bbr" 2>/dev/null || true
    
    #---------------------------------------------------------------------------
    # Security (Balanced - not paranoid)
    #---------------------------------------------------------------------------
    ./scripts/config --enable CONFIG_SECURITY
    ./scripts/config --enable CONFIG_SECCOMP
    ./scripts/config --enable CONFIG_SECCOMP_FILTER
    
    # Disable CPU vulnerability mitigations for raw performance (gaming box)
    # These cost 5-30% perf depending on workload. On a personal gaming
    # machine this is acceptable risk. Do NOT do this on a server.
    ./scripts/config --disable CONFIG_PAGE_TABLE_ISOLATION
    ./scripts/config --disable CONFIG_RETPOLINE
    ./scripts/config --disable CONFIG_MITIGATION_RETPOLINE 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_RETHUNK 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_UNRET_ENTRY 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_CALL_DEPTH_TRACKING 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_IBPB_ENTRY 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_IBRS_ENTRY 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_PAGE_TABLE_ISOLATION 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_SPECTRE_V1 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_SPECTRE_V2 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_SPECTRE_BHI 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_MDS 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_TAA 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_MMIO_STALE_DATA 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_L1TF 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_RETBLEED 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_SRSO 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_GDS 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_RFDS 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_SRBDS 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_SSB 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_ITS 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_TSA 2>/dev/null || true
    ./scripts/config --disable CONFIG_MITIGATION_VMSCAPE 2>/dev/null || true
    ./scripts/config --disable CONFIG_X86_KERNEL_IBT 2>/dev/null || true
    
    #---------------------------------------------------------------------------
    # Disable Debug Options (Performance)
    #---------------------------------------------------------------------------
    ./scripts/config --disable CONFIG_DEBUG_INFO
    ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF4
    ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF5
    ./scripts/config --disable CONFIG_DEBUG_INFO_BTF
    ./scripts/config --disable CONFIG_DEBUG_KERNEL
    ./scripts/config --disable CONFIG_SCHED_DEBUG
    ./scripts/config --disable CONFIG_DEBUG_PREEMPT
    ./scripts/config --disable CONFIG_FTRACE
    ./scripts/config --disable CONFIG_FUNCTION_TRACER
    ./scripts/config --disable CONFIG_STACK_TRACER
    ./scripts/config --disable CONFIG_KPROBES
    ./scripts/config --disable CONFIG_KPROBE_EVENTS
    
    # Disable kernel symbols in /proc (slight security + performance)
    ./scripts/config --disable CONFIG_KALLSYMS
    ./scripts/config --disable CONFIG_KALLSYMS_ALL
    
    #---------------------------------------------------------------------------
    # Module Support
    #---------------------------------------------------------------------------
    ./scripts/config --enable CONFIG_MODULES
    ./scripts/config --enable CONFIG_MODULE_UNLOAD
    ./scripts/config --enable CONFIG_MODULE_FORCE_UNLOAD
    ./scripts/config --enable CONFIG_MODVERSIONS
    
    #---------------------------------------------------------------------------
    # Wireless (Intel Wi-Fi 7 / BE devices need IWLMLD in 6.18+)
    #---------------------------------------------------------------------------
    ./scripts/config --module CONFIG_IWLWIFI
    ./scripts/config --module CONFIG_IWLMVM
    ./scripts/config --module CONFIG_IWLMLD
    ./scripts/config --module CONFIG_CFG80211
    ./scripts/config --module CONFIG_MAC80211

    #---------------------------------------------------------------------------
    # Bluetooth (Intel AX1775/BE - fix pairing, audio, HID devices)
    #---------------------------------------------------------------------------
    ./scripts/config --module CONFIG_BT
    ./scripts/config --enable CONFIG_BT_BREDR
    ./scripts/config --enable CONFIG_BT_LE
    ./scripts/config --module CONFIG_BT_HCIBTUSB
    ./scripts/config --enable CONFIG_BT_HCIBTUSB_AUTOSUSPEND
    ./scripts/config --module CONFIG_BT_INTEL
    ./scripts/config --module CONFIG_BT_RFCOMM
    ./scripts/config --enable CONFIG_BT_RFCOMM_TTY
    ./scripts/config --module CONFIG_BT_BNEP
    ./scripts/config --enable CONFIG_BT_BNEP_MC_FILTER
    ./scripts/config --enable CONFIG_BT_BNEP_PROTO_FILTER
    ./scripts/config --module CONFIG_BT_HIDP
    ./scripts/config --enable CONFIG_BT_LE_L2CAP_ECRED
    ./scripts/config --enable CONFIG_BT_LEDS
    ./scripts/config --enable CONFIG_BT_MSFTEXT
    ./scripts/config --enable CONFIG_BT_AOSPEXT
    ./scripts/config --module CONFIG_UHID
    ./scripts/config --module CONFIG_HID_GENERIC

    #---------------------------------------------------------------------------
    # Media / Video Codecs (V4L2, hardware decode support for NVDEC/VAAPI)
    #---------------------------------------------------------------------------
    ./scripts/config --enable CONFIG_MEDIA_SUPPORT
    ./scripts/config --enable CONFIG_MEDIA_CAMERA_SUPPORT 2>/dev/null || true
    ./scripts/config --enable CONFIG_MEDIA_DIGITAL_TV_SUPPORT 2>/dev/null || true
    ./scripts/config --enable CONFIG_VIDEO_DEV
    ./scripts/config --enable CONFIG_VIDEO_V4L2
    ./scripts/config --module CONFIG_VIDEO_V4L2_SUBDEV_API 2>/dev/null || true
    ./scripts/config --module CONFIG_MEDIA_USB_SUPPORT 2>/dev/null || true
    # V4L2 stateless/stateful codec API (userspace decode offload)
    ./scripts/config --enable CONFIG_V4L2_MEM2MEM_DEV 2>/dev/null || true
    ./scripts/config --enable CONFIG_MEDIA_CONTROLLER 2>/dev/null || true

    #---------------------------------------------------------------------------
    # Docker / Container Networking
    #---------------------------------------------------------------------------
    ./scripts/config --module CONFIG_BRIDGE
    ./scripts/config --enable CONFIG_BRIDGE_IGMP_SNOOPING
    ./scripts/config --module CONFIG_VETH
    ./scripts/config --module CONFIG_VXLAN
    ./scripts/config --module CONFIG_MACVLAN
    ./scripts/config --module CONFIG_IPVLAN
    ./scripts/config --module CONFIG_DUMMY

    # Netfilter / iptables (required for Docker networking)
    ./scripts/config --enable CONFIG_NETFILTER
    ./scripts/config --enable CONFIG_NETFILTER_ADVANCED
    ./scripts/config --module CONFIG_NETFILTER_XT_MATCH_CONNTRACK
    ./scripts/config --module CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
    ./scripts/config --module CONFIG_NETFILTER_XT_MATCH_IPVS
    ./scripts/config --module CONFIG_NF_CONNTRACK
    ./scripts/config --module CONFIG_NF_NAT
    ./scripts/config --module CONFIG_NF_NAT_IPV4 2>/dev/null || true
    ./scripts/config --module CONFIG_IP_NF_IPTABLES
    ./scripts/config --module CONFIG_IP_NF_FILTER
    ./scripts/config --module CONFIG_IP_NF_NAT
    ./scripts/config --module CONFIG_IP_NF_TARGET_MASQUERADE
    ./scripts/config --module CONFIG_IP6_NF_IPTABLES
    ./scripts/config --module CONFIG_IP6_NF_FILTER
    ./scripts/config --module CONFIG_IP6_NF_NAT
    ./scripts/config --module CONFIG_BRIDGE_NF_EBTABLES
    ./scripts/config --enable CONFIG_BRIDGE_NETFILTER 2>/dev/null || \
    ./scripts/config --module CONFIG_BRIDGE_NETFILTER

    # Overlay filesystem (Docker storage driver)
    ./scripts/config --module CONFIG_OVERLAY_FS

    # cgroup requirements for containers
    ./scripts/config --enable CONFIG_CGROUPS
    ./scripts/config --enable CONFIG_CGROUP_DEVICE
    ./scripts/config --enable CONFIG_CGROUP_FREEZER
    ./scripts/config --enable CONFIG_CGROUP_PIDS
    ./scripts/config --enable CONFIG_CGROUP_NET_CLASSID
    ./scripts/config --enable CONFIG_CGROUP_NET_PRIO
    ./scripts/config --enable CONFIG_CPUSETS
    ./scripts/config --enable CONFIG_MEMCG

    #---------------------------------------------------------------------------
    # Virtualization (KVM for QEMU/VMs)
    #---------------------------------------------------------------------------
    ./scripts/config --enable CONFIG_VIRTUALIZATION
    ./scripts/config --enable CONFIG_KVM
    ./scripts/config --enable CONFIG_KVM_INTEL
    
    #---------------------------------------------------------------------------
    # Gaming/Wine/Proton Support
    #---------------------------------------------------------------------------
    # Futex for Wine/Proton
    ./scripts/config --enable CONFIG_FUTEX
    ./scripts/config --enable CONFIG_FUTEX_PI
    
    # ntsync for better Windows game compatibility (if available)
    ./scripts/config --enable CONFIG_NTSYNC 2>/dev/null || true
    
    # User namespaces for containers/flatpak
    ./scripts/config --enable CONFIG_USER_NS
    ./scripts/config --enable CONFIG_NAMESPACES
    ./scripts/config --enable CONFIG_USER_NS_UNPRIVILEGED 2>/dev/null || true
    
    #---------------------------------------------------------------------------
    # CachyOS-specific Features (introduced by cachy patch)
    #---------------------------------------------------------------------------
    # Mark this as a CachyOS build
    ./scripts/config --enable CONFIG_CACHY 2>/dev/null || true

    # -O3 compiler optimization (cachy patch adds this option)
    ./scripts/config --enable CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3 2>/dev/null || true
    ./scripts/config --disable CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE 2>/dev/null || true
    ./scripts/config --disable CONFIG_CC_OPTIMIZE_FOR_SIZE 2>/dev/null || true

    # ADIOS I/O scheduler - adaptive deadline scheduler with learning-based
    # latency control, better than mq-deadline for mixed workloads
    ./scripts/config --module CONFIG_MQ_IOSCHED_ADIOS 2>/dev/null || true

    # V4L2 loopback (built into cachy patch - useful for OBS virtual camera)
    ./scripts/config --module CONFIG_V4L2_LOOPBACK 2>/dev/null || true

    # Memory management tuning knobs (anon/clean page protection ratios)
    ./scripts/config --enable CONFIG_ANON_MIN_RATIO 2>/dev/null || true
    ./scripts/config --enable CONFIG_CLEAN_LOW_RATIO 2>/dev/null || true
    ./scripts/config --enable CONFIG_CLEAN_MIN_RATIO 2>/dev/null || true

    # POC idle CPU selector - faster idle CPU selection using bitmap scanning
    # (from misc/poc-selector patch, reduces wakeup latency)
    ./scripts/config --enable CONFIG_SCHED_POC_SELECTOR 2>/dev/null || true

    #---------------------------------------------------------------------------
    # Hardware Crypto Acceleration (Intel AES-NI, PCLMUL)
    # In 6.18+, SHA/CRC hw accel is auto-selected; only AES-NI and GHASH
    # remain as separate Kconfig symbols under arch/x86/crypto
    #---------------------------------------------------------------------------
    ./scripts/config --module CONFIG_CRYPTO_AES_NI_INTEL
    ./scripts/config --module CONFIG_CRYPTO_GHASH_CLMUL_NI_INTEL
    ./scripts/config --module CONFIG_CRYPTO_SHA256
    ./scripts/config --module CONFIG_CRYPTO_CRC32C
    
    #---------------------------------------------------------------------------
    # Clang LTO (ThinLTO - whole-program optimization)
    #---------------------------------------------------------------------------
    ./scripts/config --disable CONFIG_LTO_NONE
    ./scripts/config --enable CONFIG_LTO_CLANG_THIN
    # LTO requires these
    ./scripts/config --disable CONFIG_MODVERSIONS
    ./scripts/config --disable CONFIG_GCOV_KERNEL 2>/dev/null || true

    #---------------------------------------------------------------------------
    # AutoFDO + Propeller (profile-guided optimization)
    #---------------------------------------------------------------------------
    ./scripts/config --enable CONFIG_AUTOFDO_CLANG 2>/dev/null || true
    ./scripts/config --enable CONFIG_PROPELLER_CLANG 2>/dev/null || true

    #---------------------------------------------------------------------------
    # Finalize Configuration
    #---------------------------------------------------------------------------
    # Update config with new options, using defaults for new symbols
    make ${MAKE_OPTS} olddefconfig
    
    log_success "Kernel configured"
    
    # Show key config values
    log_info "Key configuration values:"
    grep -E "^CONFIG_(PREEMPT|HZ|ZONE_DEVICE|DEVICE_PRIVATE|HMM_MIRROR|SCHED_BORE|LTO|AUTOFDO|PROPELLER)=" .config 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Kernel Compilation
#-------------------------------------------------------------------------------
compile_kernel() {
    cd "${KERNEL_DIR}"
    
    log_info "Compiling kernel with Clang/LLVM + ThinLTO, ${NPROC} threads..."
    log_info "This will take a while (20-90 minutes with LTO)..."
    
    # Build extra flags for AutoFDO/Propeller if profiles exist
    local extra_flags=""
    if [[ -f "${AUTOFDO_PROFILE}" ]]; then
        log_info "AutoFDO profile found - building with PGO!"
        extra_flags="CLANG_AUTOFDO_PROFILE=${AUTOFDO_PROFILE}"
    fi
    if [[ -f "${PROPELLER_PROFILE}_cc_profile.txt" ]]; then
        log_info "Propeller profiles found - building with Propeller!"
        extra_flags="${extra_flags} CLANG_PROPELLER_PROFILE_PREFIX=${PROPELLER_PROFILE}"
    fi

    # Compile kernel
    make ${MAKE_OPTS} ${extra_flags} || log_error "Kernel compilation failed"
    
    # Compile modules
    log_info "Compiling modules..."
    make ${MAKE_OPTS} ${extra_flags} modules || log_error "Module compilation failed"
    
    log_success "Kernel compilation complete!"
    log_info "Kernel image: ${KERNEL_DIR}/arch/x86/boot/bzImage"
    log_info "Run ./install.sh to install the kernel"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local clean=false
    local config_only=false
    
    # Parse arguments
    for arg in "$@"; do
        case $arg in
            --clean)
                clean=true
                ;;
            --config-only)
                config_only=true
                ;;
            --help|-h)
                echo "Usage: $0 [--clean] [--config-only]"
                echo "  --clean       Remove existing build before starting"
                echo "  --config-only Only configure, don't compile"
                exit 0
                ;;
        esac
    done
    
    echo "=============================================="
    echo " CachyOS Kernel Build Script"
    echo " Kernel: ${KERNEL_VERSION}"
    echo " Target: Intel i9-14900HX (Raptor Lake)"
    echo "=============================================="
    echo
    
    check_dependencies
    
    if [[ "$clean" == true ]]; then
        cleanup_old_build
    fi
    
    download_kernel
    download_patches
    apply_patches
    configure_kernel
    
    if [[ "$config_only" == true ]]; then
        log_success "Configuration complete. Run without --config-only to compile."
        exit 0
    fi
    
    compile_kernel
    
    echo
    echo "=============================================="
    echo " Build Complete!"
    echo "=============================================="
    echo " Kernel: ${KERNEL_VERSION}"
    echo " Location: ${KERNEL_DIR}"
    echo ""
    echo " Next step: Run ./install.sh to install"
    echo "=============================================="
}

main "$@"
