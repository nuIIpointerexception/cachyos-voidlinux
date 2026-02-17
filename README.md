# voidkernel

CachyOS-patched Linux kernel for Void Linux. BORE scheduler, Clang LTO, tuned for low-latency gaming.

**Target**: Intel i9-14900HX · NVIDIA · Void Linux · XFS

## Usage

```bash
# 1. Build
./build.sh

# 2. Install (kernel + DKMS + initramfs + GRUB + persistent optimizations)
sudo ./install.sh

# 3. Reboot
sudo reboot
```

## Optional: PGO (10-20% perf boost)

After booting the new kernel, collect a profile while gaming, then rebuild:

```bash
./profile_and_rebuild.sh collect   # play games for ~2 min
./profile_and_rebuild.sh build     # rebuild with profile data
sudo ./install.sh                  # reinstall
```

AutoFDO profiles are detected automatically on rebuild.

## What gets installed

**Kernel**: 6.19.x + CachyOS patches + BORE scheduler + Clang ThinLTO

**Persistent optimizations** (applied by `install.sh`):
- Sysctl tuning (swappiness, dirty pages, BBR, watchdogs off)
- Runit service: THP madvise, NVIDIA IRQ→P-cores, NVMe scheduler, performance governor

## Recovery

Old kernel is never removed. Pick it from GRUB → Advanced options.

## Dependencies

```bash
sudo xbps-install -S base-devel ncurses-devel openssl-devel elfutils-devel \
    bc git pahole flex bison perl zstd xz wget patch dracut clang lld llvm
```

## Files

```
build.sh                 # Download, patch, configure, compile
install.sh               # Install kernel + persistent system tuning
profile_and_rebuild.sh   # AutoFDO profiling for PGO rebuilds
```
