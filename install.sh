#!/bin/bash
#===============================================================================
# install.sh - CachyOS Kernel Installation Script for Void Linux
#===============================================================================
# Installs the built kernel, runs DKMS for NVIDIA, generates initramfs,
# and updates GRUB bootloader.
#
# Usage: sudo ./install.sh [--no-backup] [--skip-dkms]
#   --no-backup   Don't backup current kernel
#   --skip-dkms   Skip DKMS module rebuild (not recommended)
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Version Configuration (must match build.sh)
#-------------------------------------------------------------------------------
KERNEL_MAJOR="6"
KERNEL_MINOR="19"
KERNEL_PATCH="2"
KERNEL_VERSION="${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_PATCH}"

# Local version suffix - MUST match CONFIG_LOCALVERSION in kernel config
LOCAL_VERSION="-voltdev"
FULL_VERSION="${KERNEL_VERSION}${LOCAL_VERSION}"

#-------------------------------------------------------------------------------
# Paths
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
KERNEL_DIR="${BUILD_DIR}/linux-${KERNEL_VERSION}"

# Installation paths
BOOT_DIR="/boot"
MODULES_DIR="/lib/modules"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
    fi
}

check_build_exists() {
    if [[ ! -d "${KERNEL_DIR}" ]]; then
        log_error "Kernel build directory not found: ${KERNEL_DIR}"
    fi
    
    if [[ ! -f "${KERNEL_DIR}/arch/x86/boot/bzImage" ]]; then
        log_error "Kernel image not found. Run ./build.sh first"
    fi
    
    if [[ ! -f "${KERNEL_DIR}/System.map" ]]; then
        log_error "System.map not found. Kernel build may be incomplete"
    fi
    
    log_success "Build verification passed"
}

#-------------------------------------------------------------------------------
# Backup Functions
#-------------------------------------------------------------------------------
backup_current_kernel() {
    local current_kernel
    current_kernel=$(uname -r)
    local backup_dir="${BOOT_DIR}/backup-${current_kernel}-$(date +%Y%m%d-%H%M%S)"
    
    log_info "Backing up current kernel (${current_kernel})..."
    
    mkdir -p "${backup_dir}"
    
    # Backup kernel image
    if [[ -f "${BOOT_DIR}/vmlinuz-${current_kernel}" ]]; then
        cp "${BOOT_DIR}/vmlinuz-${current_kernel}" "${backup_dir}/"
    elif [[ -f "${BOOT_DIR}/vmlinuz" ]]; then
        cp "${BOOT_DIR}/vmlinuz" "${backup_dir}/"
    fi
    
    # Backup initramfs
    if [[ -f "${BOOT_DIR}/initramfs-${current_kernel}.img" ]]; then
        cp "${BOOT_DIR}/initramfs-${current_kernel}.img" "${backup_dir}/"
    elif [[ -f "${BOOT_DIR}/initrd.img-${current_kernel}" ]]; then
        cp "${BOOT_DIR}/initrd.img-${current_kernel}" "${backup_dir}/"
    fi
    
    # Backup config
    if [[ -f "${BOOT_DIR}/config-${current_kernel}" ]]; then
        cp "${BOOT_DIR}/config-${current_kernel}" "${backup_dir}/"
    fi
    
    # Backup System.map
    if [[ -f "${BOOT_DIR}/System.map-${current_kernel}" ]]; then
        cp "${BOOT_DIR}/System.map-${current_kernel}" "${backup_dir}/"
    fi
    
    log_success "Backup created at ${backup_dir}"
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------
install_kernel() {
    cd "${KERNEL_DIR}"
    
    log_info "Installing kernel modules..."
    make LLVM=1 modules_install || log_error "Failed to install modules"
    
    log_info "Installing kernel image..."
    
    # Copy kernel image
    cp arch/x86/boot/bzImage "${BOOT_DIR}/vmlinuz-${FULL_VERSION}"
    
    # Copy System.map
    cp System.map "${BOOT_DIR}/System.map-${FULL_VERSION}"
    
    # Copy config
    cp .config "${BOOT_DIR}/config-${FULL_VERSION}"
    
    # Create symlinks (Void Linux convention)
    ln -sf "vmlinuz-${FULL_VERSION}" "${BOOT_DIR}/vmlinuz"
    ln -sf "System.map-${FULL_VERSION}" "${BOOT_DIR}/System.map"
    ln -sf "config-${FULL_VERSION}" "${BOOT_DIR}/config"
    
    log_success "Kernel installed to ${BOOT_DIR}"
}

run_dkms() {
    log_info "Running DKMS for kernel ${FULL_VERSION}..."
    
    if ! command -v dkms &>/dev/null; then
        log_warn "DKMS not installed. NVIDIA driver may not work!"
        log_warn "Install with: sudo xbps-install -S dkms nvidia-dkms"
        return 1
    fi
    
    # Get nvidia version from dkms (pipefail-safe)
    local nvidia_version=""
    nvidia_version=$(dkms status 2>/dev/null | grep -oP 'nvidia/\K[0-9.]+' | head -1) || true
    
    if [[ -z "${nvidia_version}" ]]; then
        # Fallback: check if the package is installed even if dkms doesn't list it
        nvidia_version=$(xbps-query nvidia-dkms 2>/dev/null | grep pkgver | grep -oP '[0-9]+\.[0-9.]+' | head -1) || true
    fi
    
    if [[ -z "${nvidia_version}" ]]; then
        log_warn "nvidia-dkms not found"
        log_warn "Install with: sudo xbps-install -S nvidia-dkms"
        return 1
    fi
    
    log_info "Found NVIDIA DKMS version: ${nvidia_version}"
    
    # Remove existing build for this kernel if present (force clean rebuild)
    dkms remove nvidia/"${nvidia_version}" -k "${FULL_VERSION}" 2>/dev/null || true
    
    # Build and install
    log_info "Building nvidia/${nvidia_version} for ${FULL_VERSION} (this may take a few minutes)..."
    if dkms install nvidia/"${nvidia_version}" -k "${FULL_VERSION}" 2>&1; then
        log_success "NVIDIA DKMS module built and installed"
    else
        log_warn "DKMS install failed, trying autoinstall fallback..."
        dkms autoinstall -k "${FULL_VERSION}" 2>&1 || \
            log_warn "DKMS autoinstall also failed - may need manual intervention"
    fi
    
    # Verify
    if find "${MODULES_DIR}/${FULL_VERSION}" -name "nvidia*.ko*" 2>/dev/null | grep -q nvidia; then
        log_success "NVIDIA module verified for ${FULL_VERSION}"
    else
        log_warn "NVIDIA module not found after DKMS - check: dkms status"
    fi
}

generate_initramfs() {
    log_info "Generating initramfs..."
    
    # Void Linux uses dracut
    if command -v dracut &>/dev/null; then
        log_info "Using dracut to generate initramfs..."
        
        # Generate initramfs with NVIDIA modules
        dracut --force \
               --kver "${FULL_VERSION}" \
               --add-drivers "nvidia nvidia_modeset nvidia_uvm nvidia_drm" \
               "${BOOT_DIR}/initramfs-${FULL_VERSION}.img" || \
            log_error "Failed to generate initramfs with dracut"
        
        # Create symlink
        ln -sf "initramfs-${FULL_VERSION}.img" "${BOOT_DIR}/initramfs"
        
        log_success "Initramfs generated with dracut"
        
    elif command -v mkinitcpio &>/dev/null; then
        # Fallback to mkinitcpio (Arch-based)
        log_info "Using mkinitcpio to generate initramfs..."
        mkinitcpio -k "${FULL_VERSION}" -g "${BOOT_DIR}/initramfs-${FULL_VERSION}.img" || \
            log_error "Failed to generate initramfs with mkinitcpio"
        
        ln -sf "initramfs-${FULL_VERSION}.img" "${BOOT_DIR}/initramfs"
        log_success "Initramfs generated with mkinitcpio"
        
    else
        log_error "No initramfs generator found (dracut or mkinitcpio)"
    fi
}

update_bootloader() {
    log_info "Updating bootloader..."

    local grub_default_file="/etc/default/grub"
    local new_entry="Advanced options for Void GNU/Linux>Void GNU/Linux, with Linux ${FULL_VERSION}"

    if [[ -f "${grub_default_file}" ]]; then
        # Save the previous GRUB_DEFAULT so it can be restored on rollback
        local prev_default
        prev_default=$(grep '^GRUB_DEFAULT=' "${grub_default_file}" | head -1 | sed 's/^GRUB_DEFAULT=//' | tr -d '"')
        if [[ -n "${prev_default}" ]]; then
            echo "${prev_default}" > "${BOOT_DIR}/grub_previous_default"
            log_info "Saved previous GRUB default: ${prev_default}"
        fi

        # Set GRUB_DEFAULT to the new kernel
        log_info "Setting GRUB default to: ${new_entry}"
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${new_entry}\"|" "${grub_default_file}"

        # Ensure GRUB_SAVEDEFAULT is enabled so manually picking another
        # entry from the menu (e.g. on failure) sticks across reboots
        if grep -q '^#\?GRUB_SAVEDEFAULT' "${grub_default_file}"; then
            sed -i 's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' "${grub_default_file}"
        else
            echo 'GRUB_SAVEDEFAULT=true' >> "${grub_default_file}"
        fi

        log_success "Updated ${grub_default_file}"
    else
        log_warn "${grub_default_file} not found - cannot set default kernel"
    fi

    # GRUB
    if command -v grub-mkconfig &>/dev/null; then
        log_info "Updating GRUB configuration..."
        
        # Detect GRUB config location
        local grub_cfg=""
        if [[ -f /boot/grub/grub.cfg ]]; then
            grub_cfg="/boot/grub/grub.cfg"
        elif [[ -f /boot/grub2/grub.cfg ]]; then
            grub_cfg="/boot/grub2/grub.cfg"
        elif [[ -d /boot/efi/EFI ]] && [[ -f /boot/efi/EFI/void/grub.cfg ]]; then
            grub_cfg="/boot/efi/EFI/void/grub.cfg"
        fi
        
        if [[ -n "${grub_cfg}" ]]; then
            grub-mkconfig -o "${grub_cfg}" || log_warn "GRUB update failed"
            log_success "GRUB configuration updated"
        else
            log_warn "GRUB config not found - update manually"
        fi
        
    elif command -v update-grub &>/dev/null; then
        update-grub || log_warn "update-grub failed"
        log_success "GRUB updated"
        
    else
        log_warn "No GRUB update command found"
        log_warn "You may need to update your bootloader manually"
    fi
    
    # Also handle systemd-boot if present
    if [[ -d /boot/loader/entries ]]; then
        log_info "Creating systemd-boot entry..."
        
        cat > "/boot/loader/entries/linux-${FULL_VERSION}.conf" << EOF
title   Linux ${FULL_VERSION} (CachyOS)
linux   /vmlinuz-${FULL_VERSION}
initrd  /initramfs-${FULL_VERSION}.img
options root=UUID=$(findmnt -n -o UUID /) rw quiet
EOF
        log_success "systemd-boot entry created"
    fi
}

run_depmod() {
    log_info "Running depmod for ${FULL_VERSION}..."
    depmod -a "${FULL_VERSION}" || log_warn "depmod failed"
    log_success "Module dependencies updated"
}

#-------------------------------------------------------------------------------
# Cleanup Functions
#-------------------------------------------------------------------------------
cleanup_old_kernels() {
    log_info "Checking for old kernels to clean up..."
    
    # List installed kernels
    local kernels
    kernels=$(ls -1 "${BOOT_DIR}"/vmlinuz-* 2>/dev/null | grep -v "${FULL_VERSION}" | wc -l)
    
    if [[ ${kernels} -gt 2 ]]; then
        log_warn "Found ${kernels} other kernel versions in /boot"
        log_warn "Consider cleaning up old kernels manually"
        ls -la "${BOOT_DIR}"/vmlinuz-* | grep -v "${FULL_VERSION}"
    fi
}

#-------------------------------------------------------------------------------
# Verification
#-------------------------------------------------------------------------------
verify_installation() {
    log_info "Verifying installation..."
    
    local errors=0
    
    # Check kernel image
    if [[ ! -f "${BOOT_DIR}/vmlinuz-${FULL_VERSION}" ]]; then
        log_warn "Kernel image not found"
        ((errors++))
    fi
    
    # Check initramfs
    if [[ ! -f "${BOOT_DIR}/initramfs-${FULL_VERSION}.img" ]]; then
        log_warn "Initramfs not found"
        ((errors++))
    fi
    
    # Check modules directory
    if [[ ! -d "${MODULES_DIR}/${FULL_VERSION}" ]]; then
        log_warn "Modules directory not found"
        ((errors++))
    fi
    
    # Check NVIDIA module
    if ! find "${MODULES_DIR}/${FULL_VERSION}" -name "nvidia*.ko*" 2>/dev/null | grep -q nvidia; then
        log_warn "NVIDIA modules not found - may need manual DKMS rebuild"
    fi
    
    if [[ ${errors} -eq 0 ]]; then
        log_success "Installation verified successfully"
    else
        log_warn "Installation completed with ${errors} warnings"
    fi
}

#-------------------------------------------------------------------------------
# Persistent Gaming Optimizations
#-------------------------------------------------------------------------------
install_persistent_optimizations() {
    log_info "Installing persistent gaming optimizations..."

    # Consolidate all sysctl into one file, remove conflicting ones
    rm -f /etc/sysctl.d/70-cachyos-settings.conf /etc/sysctl.d/99-gaming.conf \
          /etc/sysctl.d/99-network.conf /etc/sysctl.d/99-networking.conf \
          /etc/sysctl.d/99-performance.conf

    cat > /etc/sysctl.d/99-gaming.conf << 'SYSCTL'
# Gaming-optimized sysctl - managed by voidkernel/install.sh

# Memory
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.page-cluster=0

# Latency
kernel.nmi_watchdog=0
kernel.watchdog=0
kernel.sched_autogroup_enabled=1

# Network
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.netdev_max_backlog=4096

# Security/misc
kernel.unprivileged_userns_clone=1
kernel.kptr_restrict=2
kernel.printk=3 3 3 3
fs.file-max=2097152
SYSCTL

    # BBR module at boot
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

    # Runit service for runtime sysfs settings (THP, IRQ, scheduler, governor)
    mkdir -p /etc/sv/gaming-optimizations
    cat > /etc/sv/gaming-optimizations/run << 'RUNIT'
#!/bin/sh
exec 2>&1

# THP
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || true
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag

# NVIDIA IRQ → P-cores (0-15)
NVIDIA_IRQ=$(grep -w nvidia /proc/interrupts 2>/dev/null | awk '{print $1}' | tr -d ':' | head -1)
[ -n "$NVIDIA_IRQ" ] && echo 0000ffff > /proc/irq/${NVIDIA_IRQ}/smp_affinity 2>/dev/null || true

# NVMe: no scheduler (lowest latency)
for dev in /sys/block/nvme*/queue/scheduler; do
    [ -f "$dev" ] && echo none > "$dev" 2>/dev/null || true
done

# CPU governor: performance
[ -d /sys/devices/system/cpu/cpu0/cpufreq ] && \
    echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true

exec chpst -b gaming-optimizations pause
RUNIT
    chmod +x /etc/sv/gaming-optimizations/run

    # Enable service (idempotent)
    ln -sf /etc/sv/gaming-optimizations /var/service/ 2>/dev/null || true

    log_success "Persistent optimizations installed (sysctl + runit service)"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local do_backup=true
    local do_dkms=true
    
    # Parse arguments
    for arg in "$@"; do
        case $arg in
            --no-backup)
                do_backup=false
                ;;
            --skip-dkms)
                do_dkms=false
                ;;
            --help|-h)
                echo "Usage: sudo $0 [--no-backup] [--skip-dkms]"
                echo "  --no-backup   Don't backup current kernel"
                echo "  --skip-dkms   Skip DKMS module rebuild"
                exit 0
                ;;
        esac
    done
    
    echo "=============================================="
    echo " CachyOS Kernel Installation Script"
    echo " Kernel: ${FULL_VERSION}"
    echo "=============================================="
    echo
    
    check_root
    check_build_exists
    
    if [[ "$do_backup" == true ]]; then
        backup_current_kernel
    fi
    
    install_kernel
    run_depmod
    
    if [[ "$do_dkms" == true ]]; then
        run_dkms
    fi
    
    generate_initramfs
    update_bootloader
    verify_installation
    cleanup_old_kernels
    
    install_persistent_optimizations
    
    echo
    echo "=============================================="
    echo " Installation Complete!"
    echo "=============================================="
    echo " Kernel: ${FULL_VERSION}"
    echo " "
    echo " Reboot to use the new kernel."
    echo " "
    echo " Verify after reboot:"
    echo "   uname -r"
    echo "   nvidia-smi"
    echo "=============================================="
}

main "$@"
