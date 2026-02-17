#!/bin/bash
#===============================================================================
# profile_and_rebuild.sh - AutoFDO + Propeller Profile-Guided Optimization
#===============================================================================
# Phase 2: After booting the Clang LTO kernel, run this to:
#   1. Collect perf profiles during your real workloads (gaming, etc.)
#   2. Convert profiles to AutoFDO format
#   3. Rebuild the kernel with PGO for 10-20% perf improvement
#
# Usage:
#   ./profile_and_rebuild.sh collect    # Collect profiles (run your games!)
#   ./profile_and_rebuild.sh build      # Rebuild with collected profiles
#   ./profile_and_rebuild.sh all        # Collect then rebuild
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_DATA="${SCRIPT_DIR}/perf.data"
AUTOFDO_PROFILE="${SCRIPT_DIR}/autofdo.profdata"
PROPELLER_PROFILE="${SCRIPT_DIR}/propeller"
PROFILE_DURATION="${PROFILE_DURATION:-120}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_deps() {
    command -v perf &>/dev/null || log_error "perf not found. Install: sudo xbps-install -S perf"
    command -v llvm-profdata &>/dev/null || log_error "llvm-profdata not found"
    command -v create_llvm_prof &>/dev/null || {
        log_warn "create_llvm_prof not found - will try autofdo package"
        log_warn "Install: https://github.com/google/autofdo or build from source"
        log_warn "Falling back to llvm-profgen if available"
        command -v llvm-profgen &>/dev/null || log_error "Neither create_llvm_prof nor llvm-profgen found"
    }
}

collect_profiles() {
    log_info "=== AutoFDO Profile Collection ==="
    log_info "Duration: ${PROFILE_DURATION} seconds"
    log_info ""
    log_info ">>> NOW: Launch your game / workload! <<<"
    log_info ">>> The profiler will record kernel activity for ${PROFILE_DURATION}s <<<"
    log_info ""

    sleep 3

    log_info "Recording kernel perf data..."
    sudo perf record -a -e br_inst_retired.near_taken:uppp \
        -b -o "${PERF_DATA}" -- sleep "${PROFILE_DURATION}" || \
        log_error "perf record failed"

    log_success "Profile collected: ${PERF_DATA} ($(du -h "${PERF_DATA}" | cut -f1))"

    log_info "Converting to AutoFDO profile..."
    local vmlinux="/home/zuzu/repos/voidkernel/build/linux-$(uname -r | sed 's/-voltdev//')/vmlinux"
    if [[ ! -f "${vmlinux}" ]]; then
        vmlinux=$(find /home/zuzu/repos/voidkernel/build -name vmlinux -type f | head -1)
    fi

    if command -v create_llvm_prof &>/dev/null; then
        create_llvm_prof --binary="${vmlinux}" \
            --profile="${PERF_DATA}" \
            --out="${AUTOFDO_PROFILE}" \
            --format=extbinary || log_error "create_llvm_prof failed"
    else
        llvm-profgen --binary="${vmlinux}" \
            --perfdata="${PERF_DATA}" \
            --output="${AUTOFDO_PROFILE}" || log_error "llvm-profgen failed"
    fi

    log_success "AutoFDO profile ready: ${AUTOFDO_PROFILE}"

    # Generate Propeller profiles if possible
    if command -v create_llvm_prof &>/dev/null; then
        log_info "Generating Propeller profiles..."
        create_llvm_prof --binary="${vmlinux}" \
            --profile="${PERF_DATA}" \
            --out="${PROPELLER_PROFILE}" \
            --format=propeller 2>/dev/null && \
            log_success "Propeller profiles ready" || \
            log_warn "Propeller profile generation failed (optional)"
    fi
}

rebuild_with_profiles() {
    [[ -f "${AUTOFDO_PROFILE}" ]] || log_error "No AutoFDO profile found. Run: $0 collect"
    log_info "Rebuilding kernel with AutoFDO profile..."
    cd "${SCRIPT_DIR}"
    ./build.sh
}

case "${1:-help}" in
    collect)
        check_deps
        collect_profiles
        log_info ""
        log_info "Next: ./profile_and_rebuild.sh build"
        ;;
    build)
        rebuild_with_profiles
        log_info "Next: sudo ./install.sh"
        ;;
    all)
        check_deps
        collect_profiles
        rebuild_with_profiles
        log_info "Next: sudo ./install.sh"
        ;;
    *)
        echo "Usage: $0 {collect|build|all}"
        echo "  collect  - Record perf profiles (run your games during this!)"
        echo "  build    - Rebuild kernel with collected profiles"
        echo "  all      - Collect then rebuild"
        echo ""
        echo "Set PROFILE_DURATION=300 for longer profiling (default: 120s)"
        ;;
esac
